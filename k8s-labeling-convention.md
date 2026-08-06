# Kubernetes Label & Selector 표준 규칙

Cantaloupe 단일 Kubernetes 클러스터의 Node, Namespace, Pod, Service 라벨과
스케줄링 기준이다.

---

## 1. Namespace

| Namespace | 구성요소 |
| --- | --- |
| `apps` | 사용자 서비스 |
| `devops` | Argo CD, Jenkins, Harbor |
| `monitoring` | Prometheus, Grafana, Alertmanager, OpenCost |
| `messaging` | Kafka, RabbitMQ |
| `logging` | OpenSearch, Fluent Bit |
| `finops` | FinOps 전용 Job/API |

팀 워크로드는 `default` Namespace에 배포하지 않는다.
`kube-system`, `kube-public`, `kube-node-lease`는 Kubernetes 기본
Namespace이므로 유지한다.

---

## 2. Node 라벨

노드가 클러스터에 Join되면 다음 네 라벨을 반드시 함께 부여한다.

- `platform`: 실제 실행 위치 (`aws`, `gcp`, `onp`)
- `role`: Node 역할 (`control-plane`, `service`, `devops`, `messaging`,
  `monitoring`, `logging`)
- `topology.kubernetes.io/region`: 가격과 장애 도메인의 리전
- `node.kubernetes.io/instance-type`: 공급자 VM 사양 또는 팀 표준 On-prem 사양명

```bash
kubectl label node cntlp-aws-cp-01 platform=aws role=control-plane \
  topology.kubernetes.io/region=ap-northeast-2 \
  node.kubernetes.io/instance-type=m7i-flex.large
kubectl label node cntlp-gcp-wk-01 platform=gcp role=monitoring \
  topology.kubernetes.io/region=asia-northeast3 \
  node.kubernetes.io/instance-type=e2-custom-4-8192
kubectl label node cntlp-onp-wk-01 platform=onp role=devops \
  topology.kubernetes.io/region=on-premise \
  node.kubernetes.io/instance-type=custom-8vcpu-16gib
```

`area`는 Node 라벨이나 스케줄링 조건으로 사용하지 않는다.

`spec.providerID`는 라벨이 아니다. AWS/GCP VM의 실제 신원을 확인하는 Kubernetes
Node 필드이며 가격 매칭 키로 사용하지 않는다. AWS는 `aws:///AZ/instance-id`,
GCP는 `gce://project/zone/instance-name` 형식을 사용한다. On-prem은 외부 Cloud
Provider 신원이 아니므로 `custom:///node-name` 팀 로컬 형식을 사용하되 AWS/GCP
provider 일치 경고 대상에서는 제외한다.

OpenCost는 `topology.kubernetes.io/region`과
`node.kubernetes.io/instance-type`으로 가격을 매칭한다. `platform`과 `role`은
비용 분류에, `spec.providerID`는 플랫폼과 실제 VM 신원 교차검증에 사용한다.

---

## 3. Pod 라벨

### 일반 워크로드

Deployment, StatefulSet, Job, CronJob의 Pod template에는 다음 라벨을
작성한다.

- `app`: 서비스 이름. 소문자 kebab-case
- `area`: 업무 영역 (`apps`, `devops`, `monitoring`, `messaging`, `logging`,
  `finops`)
- `platform`: 실제 실행 위치 (`aws`, `gcp`, `onp`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: audio-api
  namespace: apps
spec:
  selector:
    matchLabels:
      app: audio-api
  template:
    metadata:
      labels:
        app: audio-api
        area: apps
        platform: aws
    spec:
      nodeSelector:
        platform: aws
        role: service
```

### 다중 플랫폼 DaemonSet

node-exporter와 Fluent Bit처럼 여러 플랫폼의 Node에 배치되는 DaemonSet은
`app`, `area`만 작성한다. 하나의 Pod template에 고정된 `platform` 값을 쓰면
다른 플랫폼에서 실행되는 Pod의 위치가 잘못 표시되기 때문이다.

```yaml
metadata:
  labels:
    app: node-exporter
    area: monitoring
```

실제 위치는 Pod가 실행되는 Node의 `platform` 라벨로 판단한다. 특정 플랫폼에만
배치하는 DaemonSet은 `platform`을 작성할 수 있다.

---

## 4. Node 배치

Node 배치에는 `platform`과 `role`을 함께 사용한다.

```yaml
nodeSelector:
  platform: gcp
  role: monitoring
```

- 직접 작성한 매니페스트는 플랫폼별 Kustomization에서 공통 주입한다.
- Helm chart는 해당 chart의 `values.yaml`에서 설정한다.
- 메시징 워크로드는 실제 배치 위치가 확정된 뒤 selector를 추가한다.

---

## 5. Service selector

직접 작성한 Service의 `spec.selector`에는 `app`만 사용한다.

```yaml
spec:
  selector:
    app: audio-api
```

`area`와 `platform`은 Node 이동 시 변경될 수 있으므로 Service selector에 넣지
않는다. Third-party Helm chart가 생성하는 Service selector는 chart의 표준
라벨을 유지한다.

---

## 6. 작성 원칙

- 라벨 key와 value는 소문자 kebab-case를 사용한다.
- `platform`은 실행 위치, `role`은 Node 역할, `area`는 업무 영역이다.
- `area`에 `aws`, `gcp`, `onprem`을 사용하지 않는다.
- 라벨 값에는 `onprem`, `on-prem` 대신 `onp`를 사용한다.
- 사용자 ID, 요청 ID, 날짜 등 고가변성 값은 라벨에 넣지 않는다.

---

## 7. FinOps 배포 기준

- 모든 container와 initContainer는 CPU request, Memory request,
  Memory limit을 선언한다.
- CPU limit은 전체에 강제하지 않고 필요한 워크로드가 개별 설정한다.
- Kyverno 강제 대상은 `apps`, `devops`, `monitoring`, `messaging`,
  `logging`, `finops` Namespace다.
- Kubernetes 시스템 Namespace와 `kyverno`는 대상에서 제외한다.
- Third-party chart도 지원되는 `values.yaml` 항목으로 같은 기준을 적용한다.
- 불가피한 예외는 대상·사유·승인자·재검토일을 명시한다.

### Node 가격 메타데이터 검증

```bash
kubectl get nodes \
  -L platform,role,topology.kubernetes.io/region,node.kubernetes.io/instance-type

kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,PROVIDER_ID:.spec.providerID'
```

- 기존 `region + instance-type`과 같은 VM 증설은 기존 가격을 자동 적용한다.
- 새로운 VM 사양은 인프라 변경 PR과 함께 OpenCost 가격 카탈로그를 검토한다.
- 가격표에 없는 사양은 0원으로 간주하지 않고 FinOps 경고 대상으로 처리한다.
