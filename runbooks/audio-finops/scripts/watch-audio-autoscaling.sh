#!/usr/bin/env bash

# Audio FinOps 데모의 Worker Request와 KEDA/Karpenter 확장을 1초마다 관측한다.

set -euo pipefail

for command_name in kubectl watch sort uniq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

exec watch -n 1 -d -t '
echo "=== PROFILE / REQUEST ==="
kubectl -n apps get deployment \
  audio-transcode audio-transcode-burst \
  -o custom-columns="NAME:.metadata.name,PROFILE:.metadata.annotations.cantaloupe\\.io/finops-profile,CPU:.spec.template.spec.containers[0].resources.requests.cpu,MEMORY:.spec.template.spec.containers[0].resources.requests.memory,LIMIT:.spec.template.spec.containers[0].resources.limits.memory"

echo
echo "=== KEDA ==="
kubectl -n apps get scaledobject audio-transcode-burst \
  -o custom-columns="READY:.status.conditions[?(@.type==\"Ready\")].status,ACTIVE:.status.conditions[?(@.type==\"Active\")].status,MIN:.spec.minReplicaCount,MAX:.spec.maxReplicaCount"

kubectl -n apps get hpa keda-hpa-audio-transcode-burst \
  -o custom-columns="CURRENT:.status.currentReplicas,DESIRED:.status.desiredReplicas,TARGETS:.status.currentMetrics[*].external.current.averageValue"

echo
echo "=== BURST PODS PER NODE ==="
kubectl -n apps get pods \
  -l app=audio-transcode-burst \
  -o custom-columns="NODE:.spec.nodeName" \
  --no-headers | sort | uniq -c

echo
echo "=== KARPENTER CLAIMS ==="
kubectl get nodeclaims \
  -o custom-columns="CLAIM:.metadata.name,NODE:.status.nodeName,READY:.status.conditions[?(@.type==\"Ready\")].status"

echo
echo "=== BURST NODES ==="
kubectl get nodes \
  -l cantaloupe.io/node-purpose=audio-burst \
  -o custom-columns="NODE:.metadata.name,READY:.status.conditions[?(@.type==\"Ready\")].status,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type"
'
