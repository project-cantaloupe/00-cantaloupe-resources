# Audio FinOps 데모 Runbook

동일한 Audio 변환 부하를 Baseline과 Right-sized Candidate에 순서대로 실행하고,
KEDA Pod 확장과 Karpenter Node 생성 차이를 비교하는 발표용 절차다. FinOps 설계와
측정 지표는 [FinOps·Observability 현행 설계](../../docs/finops-observability.md)를
기준으로 한다.

## 책임 경계

```text
GitHub PR·CI·Merge    노트북 Browser 또는 승인된 GitHub 작업
Argo CD 배포          02-k8s-manifests/main 자동 동기화
Cluster 상태·부하     AWS Control Plane에서 이 Runbook의 스크립트 실행
```

Control Plane에는 GitHub Token을 두지 않는다. `run-rightsizing-demo.sh`는 PR을
생성하거나 병합하지 않고, 승인된 PR이 병합된 뒤 Argo CD 반영을 기다린다.

## 사전 조건

- `app-audio`가 `apps/audio` Baseline으로 `Synced/Healthy` 상태다.
- Control Plane의 `ubuntu` 사용자가 `kubectl`을 실행할 수 있다.
- `audio-finops-unexpected-burst` CronJob과 `audio-finops-load-runner` ConfigMap이
  배포돼 있다.
- KEDA `audio-transcode-burst`와 Karpenter Audio Burst NodePool이 정상이다.
- Right-sizing PR은 `02-k8s-manifests/applications/app-audio.yaml`의 Source Path를
  `overlays/audio/right-sized-candidate`로 바꾸는 승인된 변경만 포함한다.

## Control Plane 설치

저장소를 받을 수 있는 관리 Workstation에서 다음 세 파일을 Control Plane의
`/home/ubuntu`에 복사하고 실행 권한을 제한한다. `CP_HOST`에는 승인된 SSH 대상만
넣는다.

```bash
CP_HOST="ubuntu@cp-host"

ssh "$CP_HOST" \
  'umask 077; cat > /home/ubuntu/run-loadtest.sh; chmod 700 /home/ubuntu/run-loadtest.sh; bash -n /home/ubuntu/run-loadtest.sh' \
  < runbooks/audio-finops/scripts/run-loadtest.sh

ssh "$CP_HOST" \
  'umask 077; cat > /home/ubuntu/run-rightsizing-demo.sh; chmod 700 /home/ubuntu/run-rightsizing-demo.sh; bash -n /home/ubuntu/run-rightsizing-demo.sh' \
  < runbooks/audio-finops/scripts/run-rightsizing-demo.sh

ssh "$CP_HOST" \
  'umask 077; cat > /home/ubuntu/watch-audio-autoscaling.sh; chmod 700 /home/ubuntu/watch-audio-autoscaling.sh; bash -n /home/ubuntu/watch-audio-autoscaling.sh' \
  < runbooks/audio-finops/scripts/watch-audio-autoscaling.sh
```

팀원이 같은 `ubuntu` 계정으로 접속하면 세 스크립트를 실행할 수 있다. 다른 Linux
계정에는 `700` 권한 때문에 실행 권한이 없다.

## Autoscaling 관측 화면

부하 실행 전 별도 Control Plane Terminal에서 관측 스크립트를 시작한다.

```bash
/home/ubuntu/watch-audio-autoscaling.sh
```

화면은 1초마다 갱신하며 변경된 값을 강조한다. Baseline·Candidate Profile과
Request, KEDA 상태·Replica, Burst Pod의 Node별 배치, Karpenter NodeClaim과 Burst
Node를 한 화면에 표시한다. 여러 `kubectl get` 요청을 매초 실행하므로 발표와 짧은
검증 중에만 사용하고 종료할 때 `Ctrl+C`를 누른다.

## 1. Baseline 실행

Control Plane에서 Track 수와 동시 업로드 수를 지정한다. 허용 범위는 각각
`1~200`, `1~20`이다.

```bash
/home/ubuntu/run-loadtest.sh 150 20 baseline
```

Runner는 배포 중인 Python을 일회성 ConfigMap에 복사하고, 같은 인증·NetworkPolicy
경계를 가진 Job을 만든다. 고정 WAV Fixture 8개를 Job 안에서 한 번 준비해 모든
Track이 순환 사용한다. 오디오는 Public Track으로 업로드하며, 화면에는 Track별
Upload·Transcode 진행률과 최종 READY·실패 수만 표시한다.

## 2. Candidate 대기와 실행

Baseline이 끝나면 같은 Control Plane Terminal에서 실행한다.

```bash
/home/ubuntu/run-rightsizing-demo.sh 150 20
```

스크립트는 다음 순서로 동작한다.

1. Burst Worker Replica `0`, KEDA Active `False`, Burst Node `0`을 확인한다.
2. 사용자가 노트북에서 Right-sizing PR을 병합할 때까지 기다린다.
3. Argo CD가 `overlays/audio/right-sized-candidate`를 `Synced/Healthy`로 반영했는지
   확인한다.
4. Base·Burst Worker가 모두 `candidate`, CPU `50m`, Memory `160Mi`, Memory
   Limit `512Mi`인지 확인한다.
5. 같은 Track 수와 Concurrency로 Candidate Run을 실행한다.

대기 시간 기본값은 각 단계 20분이다. 운영 지연을 고려해 늘릴 때만 다음처럼
지정한다.

```bash
WAIT_SECONDS=1800 /home/ubuntu/run-rightsizing-demo.sh 150 20
```

## 3. Baseline 복구와 반복

Candidate 실행이 끝나도 스크립트가 Git 상태를 되돌리지는 않는다. 다음 실행 전
별도 복구 PR에서 Source Path를 Baseline으로 되돌린다.

```text
overlays/audio/right-sized-candidate
→ apps/audio
```

복구 PR 병합 후 다음 상태를 확인한다.

```bash
kubectl -n devops get application app-audio \
  -o custom-columns='PATH:.spec.source.path,SYNC:.status.sync.status,HEALTH:.status.health.status'

kubectl -n apps get deployment audio-transcode audio-transcode-burst \
  -o custom-columns='NAME:.metadata.name,PROFILE:.metadata.annotations.cantaloupe\.io/finops-profile,CPU:.spec.template.spec.containers[0].resources.requests.cpu,MEMORY:.spec.template.spec.containers[0].resources.requests.memory,LIMIT:.spec.template.spec.containers[0].resources.limits.memory'
```

Baseline 기준은 `apps/audio`, `baseline`, CPU `250m`, Memory `256Mi`, Memory Limit
`512Mi`다. Burst Worker·Node가 다시 0이 된 뒤 새로운 Branch와 PR로 같은 절차를
반복한다.

## 측정과 정리 경계

- Baseline과 Candidate는 같은 Track 수, Concurrency와 Fixture를 사용한다.
- READY·실패 수, Queue Drain, 처리시간, OOM·Restart, Burst Node 수와 Node Minute를
  함께 비교한다.
- Right-sizing은 Pod 수를 줄이는 기능이 아니라 같은 Pod를 더 적은 Node에 배치할
  가능성을 검증하는 Resource Request 조정이다.
- 스크립트는 실제 S3 Object, RDS Track, SQS Message, Pod와 EC2 Burst Node를 만들 수
  있다. 여러 사람이 동시에 실행하지 않는다.
- Job이나 Local ConfigMap을 삭제해도 S3 Object와 RDS Track은 삭제되지 않는다.
- 테스트 데이터는 실행 시각과 Run ID로 구분하고, 일괄 S3/RDS 직접 삭제로 정합성을
  깨뜨리지 않는다.
- 이 PR은 Kubernetes Image를 다시 빌드하지 않으므로 Harbor·Trivy·ECR 승격을
  실행하지 않는다.
