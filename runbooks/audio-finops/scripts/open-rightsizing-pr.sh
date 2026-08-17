#!/usr/bin/env bash

# Audio FinOps 데모의 Right-sizing PR을 만든다 (PR #121과 같은 변경).
#
# Baseline Run이 끝나면 app-audio의 Source Path를 apps/audio에서
# overlays/audio/right-sized-candidate로 옮겨야 한다. run-rightsizing-demo.sh가
# 2단계에서 기다리는 것이 바로 이 PR의 병합 결과다. 이 스크립트는 그 변경을 담은
# Branch와 PR을 만들고 멈춘다. 병합은 사람이 한다.
#
# 실행 위치는 GitHub Token이 있는 관리 Workstation이다. Control Plane이 아니다 —
# Runbook의 책임 경계상 Control Plane에는 Token을 두지 않는다.
#
# 사용법:
#   ./open-rightsizing-pr.sh
#   ./open-rightsizing-pr.sh --dry-run
#   MANIFESTS_REPO=/path/to/02-k8s-manifests ./open-rightsizing-pr.sh
#   SKIP_KUSTOMIZE=1 ./open-rightsizing-pr.sh

set -euo pipefail

REMOTE_URL="${REMOTE_URL:-https://github.com/project-cantaloupe/02-k8s-manifests.git}"
BASE_BRANCH="${BASE_BRANCH:-main}"
# git이 쓰는 Remote URL과 gh가 쓰는 GitHub 식별자는 다른 값이다. 기본값은
# REMOTE_URL에서 뽑되, 따로 지정할 수 있게 둔다.
derive_slug() {
  local url="${1%.git}"
  url="${url%/}"
  if [[ "$url" =~ ^[^/]+@[^:]+:(.+)$ ]]; then
    url="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/(.+)$ ]]; then
    url="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$url"
}
REPO_SLUG="${REPO_SLUG:-$(derive_slug "$REMOTE_URL")}"
BRANCH_PREFIX="${BRANCH_PREFIX:-feat/audio-right-sized-candidate}"
SKIP_KUSTOMIZE="${SKIP_KUSTOMIZE:-0}"
DRY_RUN=0

TARGET_FILE="applications/app-audio.yaml"
# 방향: Baseline → Candidate. 되돌리는 PR(#133)은 이 두 값을 맞바꾼 것이다.
FROM_PATH="apps/audio"
TO_PATH="overlays/audio/right-sized-candidate"
PR_TITLE="feat: Audio Right-sizing Candidate 전환"

while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1  (see --help)" >&2; exit 1 ;;
  esac
done

# ── 사전 점검 ───────────────────────────────────────────────────

for command_name in git gh; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

if (( ! SKIP_KUSTOMIZE )) && ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. Install it or run with SKIP_KUSTOMIZE=1" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

# 저장소를 정한다. 지정이 없으면 워크스페이스의 형제 경로를 쓰고,
# 그것도 없으면 임시 Clone을 만든다. 어느 쪽이든 아래에서 origin/main을
# 다시 받아 Worktree를 뜨므로 Local Checkout 상태에 의존하지 않는다.
CLONE_DIR=""
if [[ -z "${MANIFESTS_REPO:-}" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  sibling="${script_dir}/../../../../02-k8s-manifests"
  if [[ -d "${sibling}/.git" ]]; then
    MANIFESTS_REPO="$(cd "$sibling" && pwd)"
  else
    CLONE_DIR="$(mktemp -d)"
    echo "Local repository not found. Cloning into ${CLONE_DIR}"
    git clone --quiet "$REMOTE_URL" "${CLONE_DIR}/02-k8s-manifests"
    MANIFESTS_REPO="${CLONE_DIR}/02-k8s-manifests"
  fi
fi

if [[ ! -d "${MANIFESTS_REPO}/.git" ]]; then
  echo "Not a git repository: ${MANIFESTS_REPO}" >&2
  exit 1
fi

git_main() { git -C "$MANIFESTS_REPO" "$@"; }

RUN_ID="$(date +%Y%m%d-%H%M%S)"
BRANCH="${BRANCH_PREFIX}-${RUN_ID}"
WORKTREE=""
WORKTREE_PARENT=""

cleanup() {
  local status=$?

  if [[ -n "$WORKTREE" && -d "$WORKTREE" ]]; then
    git_main worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  fi
  if [[ -n "$WORKTREE_PARENT" ]]; then
    rm -rf "$WORKTREE_PARENT"
  fi

  # 원격에 올라가지 않은 Branch는 남길 이유가 없다 — Dry Run과 실패가 여기 걸린다.
  # 올라간 것은 PR이 참조하므로 남긴다.
  if git_main show-ref --quiet "refs/heads/${BRANCH}" \
    && ! git_main show-ref --quiet "refs/remotes/origin/${BRANCH}"; then
    git_main branch -D "$BRANCH" >/dev/null 2>&1 || true
  fi

  if [[ -n "$CLONE_DIR" ]]; then
    rm -rf "$CLONE_DIR"
  fi

  return $status
}
trap cleanup EXIT

echo "=== 1. origin/${BASE_BRANCH} 동기화 ==="

git_main fetch --quiet origin "$BASE_BRANCH"
base_sha="$(git_main rev-parse "origin/${BASE_BRANCH}")"
echo "repo=${MANIFESTS_REPO}"
echo "github=${REPO_SLUG}"
echo "base=origin/${BASE_BRANCH} (${base_sha:0:7})"

# origin/main의 파일만 본다. Local main이 앞서 있거나 더러워도 영향받지 않는다.
current_path="$(
  git_main show "origin/${BASE_BRANCH}:${TARGET_FILE}" \
    | sed -nE 's/^    path: (.+)$/\1/p'
)"
echo "current_path=${current_path:-unknown}"

if [[ "$current_path" == "$TO_PATH" ]]; then
  echo
  echo "origin/${BASE_BRANCH}이 이미 Candidate(${TO_PATH})다. 만들 PR이 없다."
  echo "Baseline으로 되돌리려면 복구 PR을 먼저 병합한다."
  exit 0
fi

if [[ "$current_path" != "$FROM_PATH" ]]; then
  echo "Unexpected source path in ${TARGET_FILE}: ${current_path:-empty}" >&2
  echo "Expected '${FROM_PATH}' before switching to '${TO_PATH}'" >&2
  exit 1
fi

# 같은 전환 PR이 이미 열려 있으면 두 번 만들지 않는다.
# 조회 자체가 실패하면 "없다"로 착각해 중복 PR을 만들 수 있으므로 여기서 멈춘다.
if ! existing="$(
  gh pr list --repo "$REPO_SLUG" --state open --base "$BASE_BRANCH" \
    --json number,headRefName,url \
    --jq "[.[] | select(.headRefName | startswith(\"${BRANCH_PREFIX}\"))] | .[0].url // empty" \
    2>&1
)"; then
  echo "Failed to list open pull requests for ${REPO_SLUG}:" >&2
  printf '%s\n' "$existing" >&2
  exit 1
fi

if [[ -n "$existing" ]]; then
  echo
  echo "이미 열려 있는 Right-sizing PR이 있다: ${existing}"
  echo "그것을 병합하거나 닫은 뒤 다시 실행한다."
  exit 0
fi

echo
echo "=== 2. Worktree에서 Branch 생성 ==="

# main을 Checkout하지 않는다. Worktree는 별도 디렉터리라 현재 작업 트리를
# 건드리지 않고, Branch를 origin/main 위에 바로 만든다.
WORKTREE_PARENT="$(mktemp -d)"
WORKTREE="${WORKTREE_PARENT}/${BRANCH//\//-}"
git_main worktree add --quiet -b "$BRANCH" "$WORKTREE" "origin/${BASE_BRANCH}"
echo "branch=${BRANCH}"
echo "worktree=${WORKTREE}"

echo
echo "=== 3. Source Path 전환 ==="

# spec.source의 path 한 줄과, 바로 앞에 붙은 설명 주석을 함께 바꾼다.
# 결과 diff는 PR #133이 되돌린 것과 정확히 반대다.
awk \
  -v target_line="    path: ${FROM_PATH}" \
  -v candidate_line="    path: ${TO_PATH}" \
  '
  BEGIN { pending = 0; done = 0 }
  /^    #/ { comment[pending++] = $0; next }
  {
    if (!done && $0 == target_line) {
      print "    # FinOps B 시나리오에서는 동일한 Worker와 KEDA 조건을 유지하고"
      print "    # CPU·Memory Request만 줄인 Candidate Overlay를 배포한다."
      print candidate_line
      pending = 0
      done = 1
      next
    }
    for (i = 0; i < pending; i++) print comment[i]
    pending = 0
    print
  }
  END {
    for (i = 0; i < pending; i++) print comment[i]
    if (!done) exit 3
  }
  ' "${WORKTREE}/${TARGET_FILE}" > "${WORKTREE}/${TARGET_FILE}.tmp" \
  || { echo "Source path line not found in ${TARGET_FILE}" >&2; exit 1; }

mv "${WORKTREE}/${TARGET_FILE}.tmp" "${WORKTREE}/${TARGET_FILE}"

if git -C "$WORKTREE" diff --quiet -- "$TARGET_FILE"; then
  echo "No change produced. Aborting." >&2
  exit 1
fi

git -C "$WORKTREE" --no-pager diff -- "$TARGET_FILE"

echo
echo "=== 4. 검증 ==="

git -C "$WORKTREE" diff --check
echo "git diff --check OK"

if (( SKIP_KUSTOMIZE )); then
  echo "kustomize render skipped (SKIP_KUSTOMIZE=1)"
else
  kubectl kustomize "${WORKTREE}/${TO_PATH}" >/dev/null
  echo "kubectl kustomize ${TO_PATH} OK"
  kubectl kustomize "${WORKTREE}/applications" >/dev/null
  echo "kubectl kustomize applications OK"
fi

# 전환 결과가 실제로 Candidate인지 렌더된 값이 아니라 파일에서 다시 확인한다.
switched_path="$(sed -nE 's/^    path: (.+)$/\1/p' "${WORKTREE}/${TARGET_FILE}")"
if [[ "$switched_path" != "$TO_PATH" ]]; then
  echo "Switch verification failed: path=${switched_path}" >&2
  exit 1
fi
echo "source path = ${switched_path}"

echo
echo "=== 5. Commit ==="

git -C "$WORKTREE" add "$TARGET_FILE"
git -C "$WORKTREE" commit --quiet -m "$PR_TITLE"
git -C "$WORKTREE" --no-pager log --oneline -1

if (( DRY_RUN )); then
  echo
  echo "=== Dry Run 종료 ==="
  echo "Push와 PR 생성을 하지 않았다. Branch ${BRANCH}는 정리된다."
  exit 0
fi

echo
echo "=== 6. Push와 PR 생성 ==="

git -C "$WORKTREE" push --quiet -u origin "$BRANCH"
echo "pushed ${BRANCH}"

if ! pr_url="$(
  gh pr create \
    --repo "$REPO_SLUG" \
    --base "$BASE_BRANCH" \
    --head "$BRANCH" \
    --title "$PR_TITLE" \
    --body "## 변경 내용

- Audio Application 배포 경로의 Right-sized Candidate Overlay 전환
- Transcode Worker CPU Request 250m에서 50m로 조정
- Transcode Worker Memory Request 256Mi에서 160Mi로 조정
- FinOps B 시나리오 Candidate 상태 적용

## 적용 범위

- Base Worker와 Burst Worker 동일 Request 적용
- Memory Limit 512Mi 유지
- KEDA 최대 Replica 6 유지
- Karpenter NodePool 최대 용량 유지

## 검증

- \`git diff --check\`
- \`kubectl kustomize overlays/audio/right-sized-candidate\`
- \`kubectl kustomize applications\`
- 실제 부하 테스트 실행 없음
" 2>&1
)"; then
  echo "PR 생성에 실패했다:" >&2
  printf '%s\n' "$pr_url" >&2
  echo >&2
  echo "Branch ${BRANCH}는 이미 Push됐다. 원인을 고친 뒤 PR만 다시 만든다:" >&2
  echo "  gh pr create --repo ${REPO_SLUG} --base ${BASE_BRANCH} --head ${BRANCH} --title '${PR_TITLE}'" >&2
  echo "쓰지 않을 Branch면 지운다:" >&2
  echo "  git push origin --delete ${BRANCH}" >&2
  exit 1
fi

echo
echo "=== 완료 ==="
echo "PR: ${pr_url}"
echo
echo "다음 단계"
echo "  1. CI(FinOps resource policy) 통과 확인 — gh pr checks ${pr_url}"
echo "  2. 리뷰 후 병합 (이 스크립트는 병합하지 않는다)"
echo "  3. Control Plane에서 Candidate Run 실행:"
echo "     /home/ubuntu/run-rightsizing-demo.sh 150 20"
