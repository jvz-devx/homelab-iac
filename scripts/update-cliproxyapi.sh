#!/usr/bin/env bash
# Update the CLIProxyAPI image pin on the Hetzner cluster, unattended.
#
#   scripts/update-cliproxyapi.sh            # update if a newer release is due
#   scripts/update-cliproxyapi.sh --dry-run  # show what would happen, change nothing
#
# Picks the newest soaked 8.x release that is on Docker Hub for amd64. If it
# is newer than the pin in apps/hetzner/cliproxyapi/deployment.yaml, the
# script rewrites that one image line, commits, pushes to origin main, asks
# Flux on Hetzner to reconcile and waits for the rollout. Then it checks the
# gate: the pod runs the new pin, the proxy still has all its accounts with
# none disabled, and /v1/models answers. If the gate fails it reverts the
# commit, rolls back the same way and exits non-zero.
#
# --dry-run still reads: it resolves the candidate and runs the gate against
# the current pin, so ssh, both keys and the parsing are tested.
#
# The last line of output starts with "RESULT:" on every exit path.
# Exit codes: 0 no-op or updated, 1 failed before any change was deployed,
# 2 rolled back and healthy, 3 rolled back but the gate still fails.
#
# Needs git, curl, jq and ssh. Settings (environment):
#   SOAK_DAYS                        minimum release age in days (default 3)
#   HETZNER_SSH                      ssh target with kubectl (default hetzner)
#   CLIPROXYAPI_URL                  default http://cliproxyapi:8317
#   CLIPROXYAPI_MANAGEMENT_KEY       or CLIPROXYAPI_MANAGEMENT_KEY_FILE
#                                    (default /run/secrets/cliproxyapi_management_key)
#   CLIPROXYAPI_API_KEY              client API key
#   GH_TOKEN                         optional, raises the GitHub API rate limit
set -euo pipefail

SOAK_DAYS=${SOAK_DAYS:-3}
HETZNER_SSH=${HETZNER_SSH:-hetzner}
CLIPROXYAPI_URL=${CLIPROXYAPI_URL:-http://cliproxyapi:8317}
MGMT_KEY_FILE=${CLIPROXYAPI_MANAGEMENT_KEY_FILE:-/run/secrets/cliproxyapi_management_key}
GH_REPO=router-for-me/CLIProxyAPI
HUB_REPO=eceasy/cli-proxy-api
TAG_RE='^v8\.[0-9]+\.[0-9]+$' # 8.x only; a new major waits for Jens
NAMESPACE=cliproxyapi
DEPLOY=cliproxyapi
APPLY_WAIT=300   # seconds for Flux to apply the new pin to the Deployment
ROLLOUT_WAIT=300 # seconds for the rollout itself
GATE_TRIES=12    # HTTP gate attempts, 10 s apart

dry_run=false
case "${1:-}" in
  --dry-run) dry_run=true ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 64 ;;
esac

RESULT="failed: the script stopped unexpectedly"
trap 'echo "RESULT: $RESULT"' EXIT
log() { echo "==> $*"; }
die() { RESULT="failed: $*"; echo "error: $*" >&2; exit 1; }

for tool in git curl jq ssh; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
cd "$repo"
manifest=apps/hetzner/cliproxyapi/deployment.yaml

# ---- keys (never printed) --------------------------------------------------

mgmt_key=${CLIPROXYAPI_MANAGEMENT_KEY:-}
if [ -z "$mgmt_key" ]; then
  [ -r "$MGMT_KEY_FILE" ] || die "no management key: set CLIPROXYAPI_MANAGEMENT_KEY or make $MGMT_KEY_FILE readable"
  mgmt_key=$(tr -d '[:space:]' <"$MGMT_KEY_FILE")
fi
api_key=${CLIPROXYAPI_API_KEY:-}
[ -n "$mgmt_key" ] || die "the management key is empty"
[ -n "$api_key" ] || die "CLIPROXYAPI_API_KEY is not set"

# ---- helpers ---------------------------------------------------------------

remote() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$HETZNER_SSH" "$@"; }

# GET url with one header. The header goes in through stdin so the key is not
# in the process list. Prints the body, then the HTTP status on its own line.
http_get() {
  curl -sS --max-time 30 -w '\n%{http_code}' --config - "$1" <<<"header = \"$2\""
}

version_gt() { # is vA.B.C newer than vX.Y.Z?
  local a b i
  IFS=. read -r -a a <<<"${1#v}"
  IFS=. read -r -a b <<<"${2#v}"
  for i in 0 1 2; do
    ((10#${a[i]} > 10#${b[i]})) && return 0
    ((10#${a[i]} < 10#${b[i]})) && return 1
  done
  return 1
}

# Read the account list. Sets ACC_COUNT, ACC_DISABLED and ACC_SUMMARY. The
# response holds tokens and emails, so only counts and states leave jq.
read_accounts() {
  local out code line
  out=$(http_get "$CLIPROXYAPI_URL/v0/management/auth-files" "Authorization: Bearer $mgmt_key") ||
    { ACC_ERROR="auth-files request failed"; return 1; }
  code=${out##*$'\n'}
  [ "$code" = 200 ] || { ACC_ERROR="auth-files returned HTTP $code"; return 1; }
  line=$(jq -r '
    .files as $f
    | [ ($f | length),
        ([$f[] | select(.disabled == true)] | length),
        ([$f[] | select((.status_message // "" | tostring) | contains("usage_limit_reached"))] | length),
        ($f | group_by(.status) | map("\(.[0].status)=\(length)") | join(","))
      ] | @tsv' <<<"${out%$'\n'*}" 2>/dev/null) ||
    { ACC_ERROR="auth-files response could not be parsed"; return 1; }
  IFS=$'\t' read -r ACC_COUNT ACC_DISABLED acc_limited acc_states <<<"$line"
  ACC_SUMMARY="$ACC_COUNT accounts, $ACC_DISABLED disabled, $acc_limited at usage limit (status: ${acc_states:-none})"
}

read_models() { # sets MODEL_COUNT
  local out code
  out=$(http_get "$CLIPROXYAPI_URL/v1/models" "X-Api-Key: $api_key") ||
    { MODELS_ERROR="/v1/models request failed"; return 1; }
  code=${out##*$'\n'}
  [ "$code" = 200 ] || { MODELS_ERROR="/v1/models returned HTTP $code"; return 1; }
  MODEL_COUNT=$(jq -r '.data | length' <<<"${out%$'\n'*}" 2>/dev/null) ||
    { MODELS_ERROR="/v1/models response could not be parsed"; return 1; }
  [ "$MODEL_COUNT" -gt 0 ] || { MODELS_ERROR="/v1/models returned an empty list"; return 1; }
}

# Check the running pods against a pin (tag@digest image reference).
check_pods() {
  local pin=$1 digest=${1##*@} pods
  remote "kubectl -n $NAMESPACE rollout status deploy/$DEPLOY --timeout=20s" >/dev/null 2>&1 ||
    { GATE_ERROR="the rollout is not complete"; return 1; }
  pods=$(remote "kubectl -n $NAMESPACE get pods -l app.kubernetes.io/name=$DEPLOY -o json") ||
    { GATE_ERROR="could not read the pods over ssh"; return 1; }
  jq -e --arg pin "$pin" --arg digest "$digest" '
    [.items[] | select(.metadata.deletionTimestamp == null)] as $pods
    | ($pods | length) > 0
      and all($pods[];
        (.spec.containers | any(.image == $pin))
        and ((.status.containerStatuses // []) | length > 0
             and all(.ready == true and (.imageID | endswith($digest)))))' \
    <<<"$pods" >/dev/null 2>&1 ||
    { GATE_ERROR="the running pod is not ready on $pin"; return 1; }
}

# The gate. Sets GATE_ERROR and returns 1 when a check fails; never exits.
# The HTTP checks retry because the tailnet route needs a moment after a
# restart.
gate() {
  local pin=$1 baseline=$2 i
  GATE_ERROR=""
  check_pods "$pin" || return 1
  log "gate 1 ok: pod is ready on $pin"
  for ((i = 1; i <= GATE_TRIES; i++)); do
    GATE_ERROR=""
    if ! read_accounts; then
      GATE_ERROR=$ACC_ERROR
    elif [ "$ACC_COUNT" -lt "$baseline" ]; then
      GATE_ERROR="the proxy has $ACC_COUNT accounts, $baseline before the update"
    elif [ "$ACC_DISABLED" -ne 0 ]; then
      GATE_ERROR="$ACC_DISABLED account(s) disabled"
    elif ! read_models; then
      GATE_ERROR=$MODELS_ERROR
    fi
    [ -z "$GATE_ERROR" ] && break
    [ "$i" -lt "$GATE_TRIES" ] && sleep 10
  done
  [ -z "$GATE_ERROR" ] || return 1
  log "gate 2 ok: $ACC_SUMMARY"
  log "gate 3 ok: /v1/models lists $MODEL_COUNT models"
}

request_reconcile() {
  local stamp='reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite'
  remote "kubectl -n flux-system annotate gitrepository flux-system $stamp" >/dev/null || return 1
  sleep 20
  remote "kubectl -n flux-system annotate kustomization apps $stamp" >/dev/null
}

# Have Flux apply origin/main and wait until the Deployment runs the pin.
# `rollout status` alone is not enough: before Flux applies the commit it
# reports the old ReplicaSet as rolled out.
roll_out() {
  local pin=$1 deadline current=""
  ROLLOUT_ERROR=""
  request_reconcile || { ROLLOUT_ERROR="could not ask Flux to reconcile over ssh"; return 1; }
  deadline=$((SECONDS + APPLY_WAIT))
  while :; do
    current=$(remote "kubectl -n $NAMESPACE get deploy $DEPLOY -o jsonpath='{.spec.template.spec.containers[0].image}'" 2>/dev/null) || current=""
    [ "$current" = "$pin" ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then
      ROLLOUT_ERROR="Flux did not apply $pin within ${APPLY_WAIT}s"
      return 1
    fi
    sleep 10
  done
  remote "kubectl -n $NAMESPACE rollout status deploy/$DEPLOY --timeout=${ROLLOUT_WAIT}s" ||
    { ROLLOUT_ERROR="the rollout did not finish within ${ROLLOUT_WAIT}s"; return 1; }
}

set_pin() { # print the manifest with the image line set to $1
  sed -E "s|^([[:space:]]*image: )$HUB_REPO:.*\$|\\1$1|" "$manifest"
}

# ---- current pin -----------------------------------------------------------

mapfile -t image_lines < <(grep -E "^[[:space:]]*image: $HUB_REPO:" "$manifest" || true)
[ "${#image_lines[@]}" -eq 1 ] || die "expected one $HUB_REPO image line in $manifest, found ${#image_lines[@]}"
old_pin=${image_lines[0]#*image: }
[[ $old_pin =~ ^$HUB_REPO:(v[0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]] ||
  die "the image line in $manifest is not pinned as tag@sha256 digest"
old_tag=${BASH_REMATCH[1]}
log "current pin: $old_pin"

# ---- checkout state --------------------------------------------------------

checkout_problem=""
git fetch --quiet origin main || die "git fetch origin main failed"
if [ -n "$(git status --porcelain)" ]; then
  checkout_problem="the checkout has uncommitted changes"
elif [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  checkout_problem="HEAD is not at origin/main"
fi
if [ -n "$checkout_problem" ]; then
  $dry_run || die "$checkout_problem"
  log "warning: $checkout_problem; a real run would refuse to start"
fi

# ---- candidate -------------------------------------------------------------

gh_args=(-fsS --max-time 30 -H "Accept: application/vnd.github+json")
if [ -n "${GH_TOKEN:-}" ]; then
  releases=$(curl "${gh_args[@]}" --config - \
    "https://api.github.com/repos/$GH_REPO/releases?per_page=100" <<<"header = \"Authorization: Bearer $GH_TOKEN\"") ||
    die "could not list $GH_REPO releases"
else
  releases=$(curl "${gh_args[@]}" "https://api.github.com/repos/$GH_REPO/releases?per_page=100") ||
    die "could not list $GH_REPO releases"
fi

# Soaked 8.x releases, newest version first.
mapfile -t soaked < <(jq -r --arg re "$TAG_RE" --argjson soak "$SOAK_DAYS" '
  map(select((.draft | not) and (.prerelease | not))
      | select(.tag_name | test($re))
      | select((.published_at | fromdateiso8601) <= (now - $soak * 86400))
      | .tag_name)
  | unique | sort_by(ltrimstr("v") | split(".") | map(tonumber)) | reverse | .[]' <<<"$releases")
log "newest 8.x release at least $SOAK_DAYS days old: ${soaked[0]:-none in the last 100 releases}"

new_tag="" new_digest=""
for tag in "${soaked[@]}"; do
  version_gt "$tag" "$old_tag" || break
  hub=$(curl -fsS --max-time 30 "https://hub.docker.com/v2/repositories/$HUB_REPO/tags/$tag" 2>/dev/null) ||
    { log "$tag is not on Docker Hub, trying an older release"; continue; }
  digest=$(jq -r 'select(any(.images[]?; .architecture == "amd64" and .os == "linux")) | .digest // empty' <<<"$hub")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
    { log "$tag has no amd64 image or digest on Docker Hub, trying an older release"; continue; }
  new_tag=$tag new_digest=$digest
  break
done

if [ -z "$new_tag" ]; then
  if $dry_run; then
    log "dry run: checking the gate against the current pin"
    read_accounts || die "baseline: $ACC_ERROR"
    log "baseline: $ACC_SUMMARY"
    gate "$old_pin" "$ACC_COUNT" || die "the gate fails on the current pin: $GATE_ERROR"
  fi
  log "nothing to do: $old_tag is the newest eligible release"
  RESULT="no-op, CLIProxyAPI stays on $old_tag (no newer 8.x release that is $SOAK_DAYS days old and on Docker Hub)"
  exit 0
fi
new_pin="$HUB_REPO:$new_tag@$new_digest"
log "candidate: $new_pin"

# ---- baseline --------------------------------------------------------------

read_accounts || die "baseline: $ACC_ERROR"
[ "$ACC_COUNT" -gt 0 ] || die "baseline: the proxy has no accounts"
[ "$ACC_DISABLED" -eq 0 ] || die "baseline: $ACC_DISABLED account(s) already disabled, fix that before updating"
baseline=$ACC_COUNT
log "baseline: $ACC_SUMMARY"

if $dry_run; then
  log "dry run: checking the gate against the current pin"
  gate "$old_pin" "$baseline" || die "the gate fails on the current pin: $GATE_ERROR"
  log "dry run: would change $manifest like this:"
  diff <(cat "$manifest") <(set_pin "$new_pin") || true
  log "dry run: would commit \"Update CLIProxyAPI to $new_tag\", push to origin main, reconcile Flux on $HETZNER_SSH and run the gate"
  RESULT="dry run, would update CLIProxyAPI from $old_tag to $new_tag"
  exit 0
fi

# ---- change, commit, push --------------------------------------------------

base_sha=$(git rev-parse HEAD)
set_pin "$new_pin" >"$manifest.tmp" && cat "$manifest.tmp" >"$manifest" && rm -f "$manifest.tmp"
if [ "$(git status --porcelain)" != " M $manifest" ] ||
  [ "$(git diff --numstat | cut -f1,2)" != $'1\t1' ]; then
  git checkout -- "$manifest"
  die "the edit touched more than the one image line; nothing committed"
fi
git add "$manifest"
# The pre-commit hook lives in the Nix store and goes stale after a garbage
# collection. Entering the dev shell reinstalls it, so retry there once.
commit_update() {
  git commit --quiet -m "Update CLIProxyAPI to $new_tag" && return 0
  command -v nix >/dev/null || return 1
  log "commit failed, retrying inside the dev shell"
  nix develop --command git commit --quiet -m "Update CLIProxyAPI to $new_tag"
}
if ! commit_update; then
  git reset --quiet --hard "$base_sha"
  die "the commit was rejected (pre-commit checks?); nothing pushed"
fi
update_sha=$(git rev-parse HEAD)
if ! git push --quiet origin HEAD:main; then
  git reset --quiet --hard "$base_sha"
  die "the push was rejected (origin/main moved?); nothing deployed, the next run retries"
fi
log "pushed $(git rev-parse --short HEAD): Update CLIProxyAPI to $new_tag"

# From here on a failure must roll back, so no step may exit on its own.

failure=""
if ! roll_out "$new_pin"; then
  failure=$ROLLOUT_ERROR
elif ! gate "$new_pin" "$baseline"; then
  failure=$GATE_ERROR
fi

if [ -z "$failure" ]; then
  log "updated: $old_tag -> $new_tag"
  RESULT="updated to $new_tag (from $old_tag); $ACC_SUMMARY"
  exit 0
fi

# ---- rollback --------------------------------------------------------------

echo "error: $failure; rolling back to $old_tag" >&2
rollback=""
if ! git revert --no-edit "$update_sha" >/dev/null; then
  rollback="git revert failed"
else
  pushed=false
  for _ in 1 2 3; do
    if git push --quiet origin HEAD:main; then pushed=true; break; fi
    git fetch --quiet origin main && git rebase --quiet origin/main || break
  done
  if ! $pushed; then
    rollback="the revert could not be pushed"
  elif ! roll_out "$old_pin"; then
    rollback=$ROLLOUT_ERROR
  elif ! gate "$old_pin" "$baseline"; then
    rollback=$GATE_ERROR
  fi
fi

if [ -z "$rollback" ]; then
  RESULT="rolled back from $new_tag to $old_tag because: $failure. The rollback passed the gate; $ACC_SUMMARY"
  exit 2
fi
RESULT="rolled back from $new_tag to $old_tag because: $failure. THE ROLLBACK ALSO FAILED: $rollback. The proxy needs attention"
exit 3
