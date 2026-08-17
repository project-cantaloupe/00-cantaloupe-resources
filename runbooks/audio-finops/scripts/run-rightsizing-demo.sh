#!/usr/bin/env bash

# Control Plane에서 Candidate GitOps 반영을 확인한 뒤 같은 부하를 실행한다.

set -euo pipefail

COUNT="${1:-150}"
CONCURRENCY="${2:-20}"
LOAD_RUNNER="${LOAD_RUNNER:-/home/ubuntu/run-loadtest.sh}"
WAIT_SECONDS="${WAIT_SECONDS:-1200}"
POLL_SECONDS=10

if [[ ! "$COUNT" =~ ^[0-9]+$ ]] || (( COUNT < 1 || COUNT > 200 )); then
  echo "COUNT must be an integer between 1 and 200" >&2
  exit 1
fi

if [[ ! "$CONCURRENCY" =~ ^[0-9]+$ ]] || (( CONCURRENCY < 1 || CONCURRENCY > 20 )); then
  echo "CONCURRENCY must be an integer between 1 and 20" >&2
  exit 1
fi

if [[ ! "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || (( WAIT_SECONDS < 60 )); then
  echo "WAIT_SECONDS must be an integer of at least 60" >&2
  exit 1
fi

for command_name in kubectl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

if [[ ! -x "$LOAD_RUNNER" ]]; then
  echo "Load runner is not executable: $LOAD_RUNNER" >&2
  exit 1
fi

deployment_value() {
  local deployment="$1"
  local jsonpath="$2"
  kubectl -n apps get deployment "$deployment" -o "jsonpath=$jsonpath" 2>/dev/null || true
}

echo "=== 1. Baseline Run 자원 정리 대기 ==="

clean=false
deadline=$((SECONDS + WAIT_SECONDS))

while (( SECONDS < deadline )); do
  replicas="$(deployment_value audio-transcode-burst '{.status.replicas}')"
  replicas="${replicas:-0}"
  active="$(
    kubectl -n apps get scaledobject audio-transcode-burst \
      -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' \
      2>/dev/null || true
  )"
  nodes="$(
    kubectl get nodes -l 'cantaloupe.io/node-purpose=audio-burst' \
      --no-headers 2>/dev/null | wc -l | tr -d ' '
  )"

  printf 'burst_replicas=%s keda_active=%s burst_nodes=%s\n' \
    "$replicas" "${active:-unknown}" "$nodes"

  if [[ "$replicas" == "0" && "$active" == "False" && "$nodes" == "0" ]]; then
    clean=true
    break
  fi

  sleep "$POLL_SECONDS"
done

if [[ "$clean" != "true" ]]; then
  echo "Burst resources did not return to zero within ${WAIT_SECONDS}s" >&2
  exit 1
fi

echo
echo "Baseline 정리 완료"
echo "GitHub에서 Audio Worker 라이트사이징 PR을 병합한다"
echo "Candidate의 Argo CD 반영을 기다린다"
echo
echo "=== 2. Candidate GitOps 반영 대기 ==="

candidate_ready=false
deadline=$((SECONDS + WAIT_SECONDS))

while (( SECONDS < deadline )); do
  path="$(
    kubectl -n devops get application app-audio \
      -o jsonpath='{.spec.source.path}' 2>/dev/null || true
  )"
  sync="$(
    kubectl -n devops get application app-audio \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true
  )"
  health="$(
    kubectl -n devops get application app-audio \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true
  )"

  base_profile="$(deployment_value audio-transcode '{.metadata.annotations.cantaloupe\.io/finops-profile}')"
  base_cpu="$(deployment_value audio-transcode '{.spec.template.spec.containers[0].resources.requests.cpu}')"
  base_memory="$(deployment_value audio-transcode '{.spec.template.spec.containers[0].resources.requests.memory}')"
  base_limit="$(deployment_value audio-transcode '{.spec.template.spec.containers[0].resources.limits.memory}')"

  burst_profile="$(deployment_value audio-transcode-burst '{.metadata.annotations.cantaloupe\.io/finops-profile}')"
  burst_cpu="$(deployment_value audio-transcode-burst '{.spec.template.spec.containers[0].resources.requests.cpu}')"
  burst_memory="$(deployment_value audio-transcode-burst '{.spec.template.spec.containers[0].resources.requests.memory}')"
  burst_limit="$(deployment_value audio-transcode-burst '{.spec.template.spec.containers[0].resources.limits.memory}')"

  printf 'path=%s sync=%s health=%s base=%s/%s/%s burst=%s/%s/%s\n' \
    "${path:-unknown}" "${sync:-unknown}" "${health:-unknown}" \
    "${base_profile:-unknown}" "${base_cpu:-unknown}" "${base_memory:-unknown}" \
    "${burst_profile:-unknown}" "${burst_cpu:-unknown}" "${burst_memory:-unknown}"

  if [[ "$path" == "overlays/audio/right-sized-candidate" \
    && "$sync" == "Synced" \
    && "$health" == "Healthy" \
    && "$base_profile" == "candidate" \
    && "$base_cpu" == "50m" \
    && "$base_memory" == "160Mi" \
    && "$base_limit" == "512Mi" \
    && "$burst_profile" == "candidate" \
    && "$burst_cpu" == "50m" \
    && "$burst_memory" == "160Mi" \
    && "$burst_limit" == "512Mi" ]]; then
    candidate_ready=true
    break
  fi

  sleep "$POLL_SECONDS"
done

if [[ "$candidate_ready" != "true" ]]; then
  echo "Candidate did not become Synced and Healthy within ${WAIT_SECONDS}s" >&2
  exit 1
fi

echo
echo "=== 3. 실제 Candidate Worker Request ==="

kubectl -n apps get deployment audio-transcode audio-transcode-burst \
  -o custom-columns='NAME:.metadata.name,PROFILE:.metadata.annotations.cantaloupe\.io/finops-profile,CPU:.spec.template.spec.containers[0].resources.requests.cpu,MEMORY:.spec.template.spec.containers[0].resources.requests.memory,LIMIT:.spec.template.spec.containers[0].resources.limits.memory'

echo
echo "=== 4. Candidate Load Run ==="
echo "tracks=$COUNT concurrency=$CONCURRENCY"

exec "$LOAD_RUNNER" "$COUNT" "$CONCURRENCY" candidate
