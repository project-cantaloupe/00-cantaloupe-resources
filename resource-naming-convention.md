# Cantaloupe Resource Naming Convention

Cantaloupe 프로젝트의 **K8s 단일 클러스터 및 멀티 클라우드(AWS/GCP/On-Prem) 인프라 자원 명명 규칙** 가이드입니다.

---

## 1. 핵심 원칙 (3초 요약)

- **소문자 kebab-case 기본**: 모든 자원명은 소문자와 하이픈(`-`)을 사용합니다. (`_`는 BigQuery 등 필수 요구 환경에서만 허용)
- **클러스터는 단 1개**: K8s 내부 자원(Namespace, Workload)에는 `cntlp`나 `aws/gcp/onp` 접두사를 붙이지 않습니다.
- **플랫폼 구분**: 클라우드 네이티브 자원 및 노드(노드풀)에만 `aws`, `gcp`, `onp` 표기를 유지합니다.
- **불변성 & 식별성**: 자원 이름은 불변이며, 환경/소유자/생명주기는 자원 이름이 아닌 **태그/라벨**로 식별합니다.

---

## 2. 토큰 표준 사전

| 토큰 | 표준값 | 비고 |
| --- | --- | --- |
| `org` | `cntlp` | 모든 클라우드 외곽 자원 접두사 (길이 제한 대비 축약형 통일) |
| `platform` | `aws`, `gcp`, `onp` | 자원의 물리적 실제 위치 |
| `component` | `api`, `transcode`, `sanitizer`, `queue`, `quarantine`, `metrics`, `finops`, `cicd`, `registry` | 기능 및 워크로드 영역 |

---

## 3. 자원 유형별 패턴표

| 구분 | 자원 | 패턴 | 예시 |
| --- | --- | --- | --- |
| **클라우드 자원**<br>(물리 종속) | S3 / GCS 버킷 | `cntlp-<platform>-<component>` | `cntlp-aws-quarantine`, `cntlp-gcp-metrics` |
| | IAM Role / SA | `cntlp-<platform>-<component>[-qualifier]` | `cntlp-aws-transcode-irsa`, `cntlp-gcp-metrics` |
| | Control Plane LB | `cntlp-aws-cp-lb` | 컨트롤플레인 전용 고정 패턴 |
| | BQ 데이터셋 | `cntlp_<component>` | 언더스코어 전용 (`cntlp_finops`) |
| **노드 자원**<br>(호스트/그룹) | 노드풀 | `<platform>-<qualifier>` | `aws-fast`, `aws-spot`, `gcp-finops`, `onp-cicd` |
| | 노드 호스트명 | `cntlp-<platform>-wk-<nn>` | `cntlp-aws-wk-01`, `cntlp-onp-wk-01` |
| **K8s 내부**<br>(플랫폼 무관) | Namespace | `<component>` | `audio`, `finops`, `cicd` |
| | Workload / SVC | `<component>[-<qualifier>]` | `api`, `transcode-fast`, `sanitizer` |

> 💡 **노드 라벨 스케줄링**: 특정 플랫폼 노드에서만 돌아야 하는 워크로드는 이름이 아니라 Pod의 `nodeSelector: platform=<aws|gcp|onp>` 라벨로 제어합니다.

---

## 4. 필수 태그 & 라벨 (비용 / 운영 가시성)

```yaml
# 클라우드 자원 태그 & K8s 라벨 공통
org: cntlp
owner: team-audio         # 이메일(@) 사용 금지 (GCP 제한)
cost-center: cc-1042
managed-by: terraform     # terraform / argocd / manual
lifecycle: permanent      # temporary인 경우 expires-on 태그 함께 표기
platform: aws             # 노드 라벨 필수 (aws | gcp | onp)
```

> ⚠️ **주의**: Prometheus 카디널리티 폭증 방지를 위해 `user-id`, `track-id` 등 고가변성 ID는 라벨/태그에 절대 추가하지 않습니다.

---

## 5. 금지 사항 (Don'ts)

- ❌ `cntlp-aws-transcode-fast` : K8s 내부 워크로드/네임스페이스에 `cntlp`나 `aws` 접두사 사용 금지 (노드 이동 시 불일치 발생)
- ❌ `Cantaloupe-API` : 대문자 사용 금지
- ❌ `cntlp-jihoon-test` : 개인명 금지 (`lifecycle: temporary` 태그 활용)
- ❌ `transcode-v2`, `audio-20260729` : 버저닝/날짜 접미사 금지 (자원 이름은 변경 불가한 불변값)

---

## 6. 적용 방식

- **신규 자원**: 본 규칙을 엄격히 준수하여 생성
- **기존 자원**: 일괄 개명 작업을 진행하지 않으며, 필수 태그/라벨을 우선적으로 적용하여 비용 및 관리 가시성을 확보
