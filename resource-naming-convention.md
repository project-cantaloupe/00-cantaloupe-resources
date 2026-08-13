# Cantaloupe Resource Naming Convention

Cantaloupe 단일 Kubernetes 클러스터와 AWS/GCP/On-Prem 인프라 자원의
명명·태그 기준이다.

---

## 1. 핵심 원칙

- 이름은 소문자 kebab-case를 사용한다. BigQuery처럼 제약이 있는 경우만
  언더스코어를 허용한다.
- Kubernetes Namespace와 Workload 이름에는 `cntlp`나 `aws/gcp/onp` 접두사를
  붙이지 않는다.
- 실행 위치는 이름이 아니라 `platform` 태그·라벨로 구분한다.
- 기존 자원을 규칙 적용만을 위해 일괄 개명하지 않는다.

---

## 2. 표준 토큰

| 토큰 | 값 | 용도 |
| --- | --- | --- |
| `org` | `cntlp` | 클라우드 자원 조직 |
| `platform` | `aws`, `gcp`, `onp` | 실제 실행 위치 |
| `role` | `control-plane`, `service`, `devops`, `monitoring`, `logging` | 현재 사용하는 Node 역할 |
| `area` | `apps`, `devops`, `monitoring`, `logging`, `secops`, `autoscaling`, `platform` | 현재 사용하는 업무·플랫폼 영역 |
| `component` | `api`, `transcode`, `metrics`, `registry`, `network`, `storage` 등 | Node가 아닌 자원의 기능 |

---

## 3. 자원 이름

| 구분 | 패턴 | 예시 |
| --- | --- | --- |
| 클라우드 자원 | `cntlp-<platform>-<component>[-qualifier]` | `cntlp-gcp-metrics-disk` |
| Node | `cntlp-<platform>-<cp\|wk>-<nn>` | `cntlp-onp-wk-01` |
| Namespace | 확정 Namespace 이름 | `apps`, `monitoring`, `storage-system` |
| Workload·Service | `<app>[-qualifier]` | `audio-api`, `transcode-fast` |

인프라 디렉터리명도 `aws`, `gcp`, `onp`로 통일한다.

시스템 Add-on Namespace는 기능 중심의 `<component>-system` 이름을 사용한다.
공급자별 `gcp-*`, `aws-*` Namespace를 만들지 않고 실행 위치는 `platform`
라벨로 구분한다. 현재 확정된 공통 스토리지 Namespace는 `storage-system`이다.

`finops`는 독립 Namespace나 `area`가 아니라 `monitoring` 영역에서 수행하는
관측 기능이며 필요하면 `category=finops`로 구분한다. 실제 메시징 플랫폼이 없는
현재 상태에서는 `messaging` Namespace·`role`·`area`를 만들지 않는다.

---

## 4. 클라우드 자원 태그

AWS·GCP에서 지원하는 자원에는 다음 공통 태그를 적용한다.

```yaml
org: cntlp
owner: team-platform
managed-by: terraform
lifecycle: permanent
platform: aws
```

Node에는 `role`을 추가한다.

```yaml
role: service
```

디스크·DB·버킷처럼 Node가 아닌 자원에는 필요할 때 `component`를 추가한다.

```yaml
component: metrics
```

- `owner`: 자원 변경·삭제를 판단할 책임 팀
- `managed-by`: `terraform`, `argocd`, `manual` 등 관리 주체
- `lifecycle`: `permanent` 또는 `temporary`
- `temporary` 자원에는 `expires-on`을 함께 기록한다.
- `data-class`는 보안 분류가 필요한 자원에만 사용한다.
- 실제 회계 비용센터가 없으므로 `cost-center`는 사용하지 않는다.

Proxmox는 `key=value` 태그를 지원하지 않으므로 운영 자동화에 필요한
`platform-onp`, `role-devops`만 사용한다.

---

## 5. 금지 사항

- `cntlp-aws-audio-api`: Kubernetes Workload에 조직·플랫폼 접두사 사용 금지
- `Cantaloupe-API`: 대문자 사용 금지
- `cntlp-jihoon-test`: 개인 이름 사용 금지
- `audio-20260729`: 날짜를 불변 자원명에 사용 금지
- 사용자 ID·요청 ID 등 고가변성 값을 태그·라벨에 사용 금지
