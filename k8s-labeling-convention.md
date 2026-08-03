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
| `secops` | Keycloak, External Secrets Operator |

팀 워크로드는 `default` Namespace에 배포하지 않는다.
`kube-system`, `kube-public`, `kube-node-lease`는 Kubernetes 기본
Namespace이므로 유지한다.

`kyverno`는 별도 Namespace를 유지한다. 차트 기본값이고 7절이 이미 강제
대상에서 제외하고 있다. Namespace는 `kyverno`지만 Pod의 `area` 라벨은
`secops`다. **Namespace와 `area`가 항상 1:1인 것은 아니다.**

### 특권이 필요한 워크로드는 Namespace를 따로 준다

Pod Security Admission 등급은 Namespace 단위로만 줄 수 있다. 특권이 필요한
워크로드를 다른 것과 같은 Namespace에 두면 **그 Namespace 전체가 하드닝을
잃는다.** node-exporter가 `monitoring`을, Fluent Bit이 `logging`을 이미 그렇게
만들고 있다.

새로 들이는 것 중 특권이 필요한 것은 전용 Namespace를 준다.

| 워크로드 | 왜 특권이 필요한가 | Namespace |
| --- | --- | --- |
| Kepler | RAPL 전력 카운터를 읽는다 | 전용 (`kepler`) |
| Falco | eBPF 또는 커널 모듈로 시스템콜을 본다 | 전용 (`falco`) |

**Falco를 `secops`에 넣지 않는다.** 넣으면 Keycloak이 하드닝 없는
Namespace에서 돌게 된다. 신원 서버는 클러스터에서 가치가 가장 높은 표적이다.

---

## 2. Node 라벨

노드가 클러스터에 Join되면 다음 두 라벨을 반드시 함께 부여한다.

- `platform`: 실제 실행 위치 (`aws`, `gcp`, `onp`)
- `role`: Node 역할 (`control-plane`, `service`, `devops`, `messaging`,
  `monitoring`, `logging`)

```bash
kubectl label node cntlp-aws-cp-01 platform=aws role=control-plane
kubectl label node cntlp-aws-wk-01 platform=aws role=service
kubectl label node cntlp-gcp-wk-01 platform=gcp role=monitoring
kubectl label node cntlp-gcp-wk-02 platform=gcp role=logging
kubectl label node cntlp-onp-wk-01 platform=onp role=devops
```

`area`는 Node 라벨이나 스케줄링 조건으로 사용하지 않는다.

---

## 3. Pod 라벨

### 일반 워크로드

Deployment, StatefulSet, Job, CronJob의 Pod template에는 다음 라벨을
작성한다.

- `app`: 서비스 이름. 소문자 kebab-case
- `area`: 업무 영역 (`apps`, `devops`, `monitoring`, `messaging`, `logging`,
  `finops`, `secops`)
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
  `logging`, `finops`, `secops` Namespace다.
- Kubernetes 시스템 Namespace와 `kyverno`는 대상에서 제외한다.
  특권이 필요해 전용 Namespace를 받은 것(`kepler`, `falco`)도 자원 기준은
  같이 적용하되, Pod 하드닝은 PSA 등급으로 따로 정한다.
- Third-party chart도 지원되는 `values.yaml` 항목으로 같은 기준을 적용한다.
- 불가피한 예외는 대상·사유·승인자·재검토일을 명시한다.
