# Kubernetes Label & Selector 표준 규칙

Cantaloupe 프로젝트의 **Kubernetes Node, Namespace, Pod, Service 라벨링 및 셀렉터 작성 가이드**입니다.

---

## 1. Node 라벨 규칙 (초기 노드 Join 시)

노드가 Kubernetes 클러스터에 Join된 직후 노드에 필수 라벨 2개를 부여합니다.

- `platform`: `aws`, `gcp`, `onp` (사설/온프렘)
- `role`: 역할에 맞게 부여 (`control-plane`, `service`, `devops`, `messaging`, `monitoring`, `logging` 등)

### 적용 예시

```bash
# AWS 노드
kubectl label node cantaloupe-aws-cp-01 platform=aws role=control-plane
kubectl label node cantaloupe-aws-wk-01 platform=aws role=service
kubectl label node cantaloupe-aws-wk-02 platform=aws role=service

# On-Prem (사설) 노드
kubectl label node cantaloupe-onp-wk-01 platform=onp role=devops
kubectl label node cantaloupe-onp-wk-02 platform=onp role=service

# GCP 노드
kubectl label node cantaloupe-gcp-wk-01 platform=gcp role=messaging
kubectl label node cantaloupe-gcp-wk-02 platform=gcp role=monitoring
kubectl label node cantaloupe-gcp-wk-03 platform=gcp role=logging
```

---

## 2. Namespace 규칙

비용 분리 및 기능 영역 격리에 따라 세분화하여 네임스페이스를 관리합니다.

| Namespace | 구성 요소 | 비고 |
| --- | --- | --- |
| `apps` | 사용자 앱 서비스 | 도메인별 비용 분리가 필요한 경우 `app-user`, `app-order`, `app-payment` 등으로 세분화 가능 |
| `devops` | Argo CD, Harbor, CI/CD 러너 |  |
| `monitoring` | Prometheus, Grafana, OpenCost, Kepler |  |
| `messaging` | Kafka, RabbitMQ |  |
| `logging` | Logstash, OpenSearch, Fluent Bit |  |
| `finops` | 비용 분석 및 예산 관리 |  |

---

## 3. Pod & Service 라벨 작성 규칙

### 3-1. Pod 라벨 (Pod Template)

Deployment / StatefulSet의 **Pod template (`spec.template.metadata.labels`)**에 작성합니다.

- `app`: 애플리케이션 이름 (`order-api`, `prometheus`, `kafka`, `argocd` 등)
- `area`: 기능 영역 (`apps`, `devops`, `monitoring`, `logging`, `messaging`, `finops`)
- `platform`: 실행 노드의 물리적 위치 (`aws`, `gcp`, `onp`)

#### Deployment 작성 예시
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-api
  namespace: apps
spec:
  replicas: 2
  selector:
    matchLabels:
      app: order-api
  template:
    metadata:
      labels:
        app: order-api
        area: apps
        platform: aws
    spec:
      containers:
        - name: order-api
          image: cntlp-registry.internal/apps/order-api:1.0
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
```

### 3-2. Service 라벨 & Selector

Service의 `spec.selector`에는 **`app` 라벨 하나만 작성**합니다.

> ⚠️ `area`, `platform` 라벨을 Service selector에 포함하지 않습니다. (노드 스케줄링 이동 시 엔드포인트 연결 유실 방지)

#### Service 작성 예시
```yaml
apiVersion: v1
kind: Service
metadata:
  name: order-api
  namespace: apps
  labels:
    app: order-api
spec:
  type: ClusterIP
  selector:
    app: order-api
  ports:
    - port: 80
      targetPort: 8080
```
