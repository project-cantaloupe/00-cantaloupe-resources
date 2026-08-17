#!/usr/bin/env bash

# Audio FinOps Baseline/Candidate 일회성 부하를 동일한 Runner 계약으로 실행한다.

set -euo pipefail

COUNT="${1:-150}"
CONCURRENCY="${2:-20}"
PHASE="${3:-baseline}"

LOCAL_CONFIGMAP="audio-finops-load-runner-local"
CRONJOB="audio-finops-unexpected-burst"

if [[ ! "$COUNT" =~ ^[0-9]+$ ]] || (( COUNT < 1 || COUNT > 200 )); then
  echo "COUNT must be an integer between 1 and 200" >&2
  exit 1
fi

if [[ ! "$CONCURRENCY" =~ ^[0-9]+$ ]] || (( CONCURRENCY < 1 || CONCURRENCY > 20 )); then
  echo "CONCURRENCY must be an integer between 1 and 20" >&2
  exit 1
fi

if [[ "$PHASE" != "baseline" && "$PHASE" != "candidate" ]]; then
  echo "PHASE must be baseline or candidate" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# GitOps ConfigMap은 바꾸지 않고 배포 중인 Runner Python을 Local 파일로 읽는다.
kubectl -n apps get configmap audio-finops-load-runner \
  -o jsonpath='{.data.runner\.py}' > "$TEMP_DIR/runner.py"

if [[ ! -s "$TEMP_DIR/runner.py" ]]; then
  echo "Failed to read runner.py from the deployed ConfigMap" >&2
  exit 1
fi

# Remote Git을 변경하지 않고 Local Job에만 곡명과 KST 실행시간 형식을 적용한다.
python3 - "$TEMP_DIR/runner.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")

if "SONG_ADJECTIVES = (" not in source:
    old_titles = '''PROFILE_TITLES = {
    "steady": "Steady",
    "scheduled-peak": "Scheduled Peak",
    "unexpected-burst": "Reactive Burst",
    "web-validation": "Web Validation",
}'''
    new_titles = '''# Local presentation titles: 20 x 10 gives 200 unique song-style names.
SONG_ADJECTIVES = (
    "Midnight", "Neon", "Golden", "Silent", "Velvet",
    "Electric", "Fading", "Crystal", "Lunar", "Endless",
    "Blue", "Scarlet", "Northern", "Distant", "Summer",
    "Winter", "Broken", "Hidden", "Burning", "Ocean",
)
SONG_NOUNS = (
    "Echoes", "Horizon", "Reverie", "Skyline", "Afterglow",
    "Signals", "Gravity", "Starlight", "Rain", "Dreams",
)'''
    old_function = '''def track_title(index, fixture_index, seconds):
    phase = PHASE.replace("-", " ").title()
    profile = PROFILE_TITLES.get(PROFILE, PROFILE.replace("-", " ").title())
    return (
        f"FinOps {phase} · {profile} · {run_time_label(RUN_ID)} · "
        f"#{index + 1:03d} · {seconds}초 · 패턴 {fixture_index + 1}"
    )'''
    new_function = '''def track_title(index):
    adjective = SONG_ADJECTIVES[index % len(SONG_ADJECTIVES)]
    noun = SONG_NOUNS[(index // len(SONG_ADJECTIVES)) % len(SONG_NOUNS)]
    return f"{adjective} {noun} · {run_time_label(RUN_ID)}"'''

    replacements = (
        (old_titles, new_titles),
        ('strftime("%m/%d %H:%M KST")', 'strftime("%m/%d %H:%M:%S KST")'),
        (old_function, new_function),
        ("title = track_title(index, fixture_index, seconds)", "title = track_title(index)"),
    )
    for old, new in replacements:
        if old not in source:
            raise SystemExit("deployed Runner does not match the expected local patch boundary")
        source = source.replace(old, new, 1)

compile(source, str(path), "exec")
path.write_text(source, encoding="utf-8")
PY

kubectl -n apps create configmap "$LOCAL_CONFIGMAP" \
  --from-file=runner.py="$TEMP_DIR/runner.py" \
  --dry-run=client \
  -o yaml \
| kubectl apply -f -

RUN_TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
RUN_DATE="$(date +%Y-%m-%d)"
JOB_NAME="audio-finops-${PHASE}-${RUN_TIMESTAMP}"

# CronJob의 인증과 NetworkPolicy 경계는 재사용하고 Runner ConfigMap만 Local로 바꾼다.
kubectl -n apps create job \
  --from="cronjob/$CRONJOB" \
  "$JOB_NAME" \
  --dry-run=client \
  -o yaml \
| kubectl set env \
    --local \
    -f - \
    --containers=runner \
    LOAD_COUNT="$COUNT" \
    LOAD_CONCURRENCY="$CONCURRENCY" \
    EXPERIMENT_PHASE="$PHASE" \
    EXPERIMENT_END_DATE="$RUN_DATE" \
    RUN_ID="$JOB_NAME" \
    AUDIO_VISIBILITY=public \
    -o yaml \
| kubectl patch \
    --local \
    -f - \
    --type=strategic \
    --patch '{"spec":{"template":{"spec":{"volumes":[{"name":"runner","configMap":{"name":"audio-finops-load-runner-local"}}]}}}}' \
    -o yaml \
| kubectl apply -f -

echo
echo "JOB_NAME=$JOB_NAME"
echo "COUNT=$COUNT CONCURRENCY=$CONCURRENCY PHASE=$PHASE"
echo "Local title example: Midnight Echoes · Run time KST"
echo

cat > "$TEMP_DIR/format_logs.py" <<'PY'
import datetime as dt
import json
import sys

KST = dt.timezone(dt.timedelta(hours=9))


def display_time(raw):
    try:
        return dt.datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(KST).strftime("%H:%M:%S")
    except ValueError:
        return raw


for raw_line in sys.stdin:
    line = raw_line.strip()
    if not line or "waiting to start: ContainerCreating" in line:
        continue

    if "FINOPS_RUN_RESULT=" in line:
        timestamp, _, remainder = line.partition(" ")
        payload = json.loads(remainder.split("FINOPS_RUN_RESULT=", 1)[1])
        counts = payload.get("status_counts", {})
        ready = int(counts.get("READY", 0))
        failed = sum(int(value) for key, value in counts.items() if key != "READY")
        failed += int(payload.get("upload_errors", 0))
        started = dt.datetime.fromisoformat(payload["started_at"])
        finished = dt.datetime.fromisoformat(payload["finished_at"])
        elapsed = (finished - started).total_seconds()
        print(
            f"[{display_time(timestamp)} KST] RUN COMPLETE | "
            f"requested={payload['requested']} submitted={payload['submitted']} "
            f"ready={ready} failed={failed} elapsed={elapsed:.1f}s",
            flush=True,
        )
        continue

    timestamp, separator, message = line.partition(" ")
    if not separator or not message.startswith("{"):
        if any(word in line.lower() for word in ("error", "failed", "traceback")):
            print(f"[ERROR] {line}", flush=True)
        continue

    try:
        event = json.loads(message)
    except json.JSONDecodeError:
        print(f"[ERROR] {line}", flush=True)
        continue

    event_name = event.get("event")
    clock = display_time(timestamp)

    if event_name == "fixture_cache_ready":
        mib = float(event["bytes"]) / 1024 / 1024
        print(
            f"[{clock} KST] FIXTURES READY | "
            f"cached={event['fixtures']} size={mib:.1f}MiB prepare={event['prepare_seconds']}s",
            flush=True,
        )
    elif event_name == "run_started":
        print(
            f"[{clock} KST] RUN START | run_id={event['run_id']} "
            f"profile={event['profile']} tracks={event['count']} "
            f"concurrency={event['concurrency']}",
            flush=True,
        )
    elif event_name == "upload_complete":
        current = int(event["submitted"])
        total = int(event["requested"])
        print(f"[{clock} KST] UPLOAD | {current}/{total} submitted", flush=True)
    elif event_name == "terminal_status":
        current = int(event["completed"])
        total = int(event["requested"])
        status = event.get("status", "UNKNOWN")
        print(f"[{clock} KST] TRANSCODE | {current}/{total} status={status}", flush=True)
    elif event_name in ("upload_failed", "tracking_failed"):
        print(f"[{clock} KST] ERROR | {event_name} {event}", flush=True)
PY

# 화면에는 발표용 진행률만 표시하고 원본 로그는 Kubernetes Pod에 그대로 보존한다.
kubectl -n apps logs -f "job/$JOB_NAME" -c runner --timestamps 2>&1 \
| python3 -u "$TEMP_DIR/format_logs.py"
