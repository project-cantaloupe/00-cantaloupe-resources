# FinOps·OpenCost·Metrics·Right-sizing 현행 설계

## 문서 기준과 책임 경계

이 문서는 다음 자료를 실행 사실의 우선순위로 사용한다.

1. `02-k8s-manifests`의 Argo CD Application, Helm values, collector,
   PrometheusRule, pricing catalog
2. 현재 Grafana에서 사용하는 `Audio S3 Lifecycle FinOps`,
   `Platform Overview`, `Kubernetes FinOps` 대시보드
3. `01-infra-provisioning`의 Terraform·Ansible 구현

`00-cantaloupe-resources`는 의도와 계약을, `01-infra-provisioning`은 VM·IAM·S3와
노드 온보딩을, `02-k8s-manifests`는 클러스터 내 수집·계산·표시 구현을
소유한다. `03-app-audio`는 서비스 메트릭과 부하 행동을 소유한다.

## 현재 구성

```text
cloud/VM/S3/Proxmox
  └─ 01: 노드 신원·라벨, read-only IAM, S3 Lifecycle
       └─ Kubernetes
            ├─ Metrics Server → metrics.k8s.io → VPA Recommender
            ├─ kube-state-metrics/node-exporter/ServiceMonitor → Prometheus
            ├─ OpenCost + 검증된 custom pricing catalog → 비용 배분
            ├─ VPA/Provider/S3 collector → Pushgateway/Prometheus
            ├─ PrometheusRule → 횡단 메트릭·경고
            └─ Grafana → 운영·FinOps 의사결정 보기
```

중앙 Prometheus는 GCP `monitoring` 노드에 배치되지만 AWS·GCP·On-prem
노드와 워크로드를 함께 관측한다. 현재 보존 기간은 15일,
Prometheus PVC는 20Gi이며 `gcp-pd-retain`을 사용한다.

## OpenCost 비용 모델

OpenCost는 `monitoring` Namespace의 Prometheus를 조회하며, Cloud Cost 기능은
꺼져 있다. Node 가격은 Cloud 청구 API가 아니라
`platform/gcp/opencost/pricing-catalog.yaml`에서 생성된 CSV custom pricing을
사용한다. 노드 매칭 키는
`topology.kubernetes.io/region` + `node.kubernetes.io/instance-type`이다.
`platform`, `role`, `spec.providerID`는 분류·신원·무결성 검증에 사용한다.

- Node cost: 현재 노드 용량을 유지할 때의 시간당 기준 비용
- Workload allocated cost: OpenCost가 request/사용량 기준으로 배분한 비용
- Idle cost: Node cost에서 워크로드 배분분을 뗀 미배분 용량 비용
- PVC cost: GCP CSI의 provisioned capacity와 서울 `pd-standard` 기준 가격

On-prem hostPath 스토리지는 PVC 비용에 더하지 않고 Node TCO에 포함한다.
가격 표 누락·불일치·노후화와 필수 라벨·providerID 누락은
PrometheusRule과 Alertmanager의 `category=finops` 경로로 탐지한다.

## VPA와 Right-sizing의 정확한 의미

VPA는 `1.7.0` Recommender만 설치한다. Updater와 Admission Controller는
설치하지 않고 모든 VPA는 `updateMode: Off`이다. Metrics Server는
chart `3.13.1`/app `0.8.1`이며 kubelet serving certificate를 검증한다.
`--kubelet-insecure-tls`는 사용하지 않는다.

대시보드의 유일한 Kubernetes 표준 권고값은 VPA Recommender의
Lower/Target/Upper이다. Prometheus의 최근 7일 P95/P99/Max, OOM,
throttling, HPA, request, limit은 VPA 값의 안전성과 비용 맥락을 판단하는
보조 근거이지 두 번째 VPA 권고가 아니다.

`vpa-recommendation-collector`는 5분마다 VPA status를 Pushgateway에
보낸다. VPA 관찰 6시간은 제한적 수동 검토의 최소 기준이고,
대시보드의 `7일 관찰 완료`는 168시간을 뜻한다. 둘 다 자동 승인이
아니며 대표 부하, SLO, owner 승인 후 Git에서 request를 변경한다.

Provider VM 추천은 GCP Recommender(매일 09:15 KST)와 AWS Compute
Optimizer(매일 09:30 KST)의 read-only collector가 수집한다. On-prem
추천은 최근 7일 Node P95와 내부 profile/TCO 정책으로 계산한다.
이 결과는 모두 수동 검토 대상이며 VM이나 Pod를 변경하지 않는다.

## 대시보드 계약

| 대시보드 | 주요 답변 | 해석 제한 |
| --- | --- | --- |
| `Platform Overview` | Node/Pod/target, CPU·Memory, Karpenter/KEDA, Fluent Bit, PVC·filesystem 상태 | 운영 상태 보기이며 비용 추천을 만들지 않음 |
| `Kubernetes FinOps` | Node/PVC 월 Run-rate, OpenCost 배분, Idle, VPA/VM 검토 후보 | 730시간 환산값은 실제 청구액이 아니고 Idle은 확정 절감액이 아님 |
| `Audio S3 Lifecycle FinOps` | 현재/이전 버전 용량, class별 Run-rate, Lifecycle 적용·가정 효과 | 명시된 Audio bucket만 6시간 주기로 수집; AWS 계정 전체 자동 탐색이 아님 |

`Kubernetes FinOps`의 선택 기간 누적 Node/Karpenter 비용은 시간적분한
추정치이다. 월 Run-rate는 현재 구성이 730시간 유지된다는 가정이다.
절감은 request 조정 뒤 VM 축소·제거 또는 Karpenter consolidation으로 실제
자원이 사라지고 안정성과 청구 결과를 확인했을 때만 실현된 것으로 기록한다.

S3 120일 Lifecycle 비교는 오늘의 Quarantine 용량을 하나의 가상 파일
묶음으로 고정하고 Standard 30일, Standard-IA 30일, Glacier Instant
Retrieval 60일을 적용한 시나리오이다. 미래 실제 청구액 예측이 아니다.

## 변경·검증 규칙

1. 가격 변경은 catalog를 수정한 뒤 `generate_pricing.py` 생성과
   `--check`를 통과시킨다.
2. On-prem profile 변경은 `generate_onprem_rightsizing.py --check`를
   통과시킨다.
3. 새 노드는 `platform`, `role`, region, instance type과
   `spec.providerID`를 확인한다.
4. VPA는 `Off`인지, Updater/Admission Controller가 렌더링되지 않는지
   검증한다.
5. 대시보드 변경은 패널 숫자보다 원본 메트릭, recording rule,
   collector 최신성, 가격 coverage를 먼저 검증한다.
