#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Harbor Discovery – Inventory Only (No Migration)
# ------------------------------------------------------------------------------
# Discovers repositories in a Harbor project and collects the last N artifacts
# per repository (sorted by push_time desc). Emits NDJSON + CSV reports.
#
# Requirements: curl, jq
#
# AuthN: Basic auth via HARBOR_USER / HARBOR_PASS (robot account recommended)
#
# Usage:
#   ./harbor-discovery.sh --project myproject \
#       --harbor-api https://harbor.example.com/api/v2.0 \
#       --user robot$ci-bot --pass '******' \
#       --artifacts 5 \
#       --out ./reports \
#       [--insecure]
#
# Security notes:
#   - Avoid --insecure unless you explicitly trust the network path.
#   - Prefer a low-privilege robot account with read-only permissions.
#   - Credentials should come from a secure secret store (CI variables, env).
# ------------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: harbor-discovery.sh --project <name> --token <pass> [options]

Required:
  --project       Harbor project name (e.g., 'onboarding')
  --token         Harbor token (generated @ registry.mydbops.com/api/v2.0)

Options:
  --artifacts N   Max artifacts per repository to fetch (default: 5)
  --page-size N   Pagination size for repository listing (default: 100)
  --out DIR       Output directory (default: ./harbor-reports)
  --insecure      Skip TLS verification for Harbor API (not recommended)
  -h, --help      Show help
EOF
}

# ---------- Defaults ----------
PROJECT=""
HARBOR_API=""
HARBOR_TOKEN=""
ARTIFACTS_PER_REPO=5
PAGE_SIZE=100
OUT_DIR="./harbor-reports"


# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)      PROJECT="$2"; shift 2 ;;
    --token)         HARBOR_TOKEN="$2"; shift 2 ;;
    --artifacts)    ARTIFACTS_PER_REPO="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# ---------- Validations ----------
for v in HARBOR_API PROJECT HARBOR_TOKEN; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: Missing required arg/env: $v" >&2
    usage; exit 1
  fi
done

command -v jq >/dev/null || { echo "ERROR: jq not found in PATH"; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not found in PATH"; exit 1; }

mkdir -p "$OUT_DIR"

TS() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() { echo -e "$(TS) | [$1] | $2"; }

API() {
  # $1: path+query (absolute URL allowed)
  local url="$1"
  if [[ "$url" != http*://* ]]; then
    url="${HARBOR_API%/}/$url"
  fi
  curl -sS -H "authorization: Basic ${HARBOR_TOKEN}" \
    -H "Accept: application/json" \
    "$url"
}

# ---------- Paginated repository fetch ----------
# Returns a newline-delimited list of repository names.
fetch_all_repositories() {
  local page=1
  local names=()
  while :; do
    local resp
    resp="$(API "projects/${PROJECT}/repositories?page=${page}&page_size=${PAGE_SIZE}")"
    # Empty / invalid response short-circuits
    if [[ -z "$resp" ]] || [[ "$resp" == "null" ]]; then
      break
    fi

    # Extract repo names
    local batch
    batch="$(echo "$resp" | jq -r '.[].name')"
    if [[ -z "$batch" ]]; then
      break
    fi
    # Append to array
    while IFS= read -r n; do
      [[ -n "$n" ]] && names+=("$n")
    done <<< "$batch"

    # If returned fewer than page size, last page reached
    local count
    count="$(echo "$resp" | jq 'length')"
    if [[ "$count" -lt "$PAGE_SIZE" ]]; then
      break
    fi
    page=$((page+1))
  done

  printf "%s\n" "${names[@]}"
}

# ---------- Artifact discovery for one repo ----------
# Emits NDJSON lines to stdout for up to ARTIFACTS_PER_REPO artifacts.
discover_repo_artifacts() {
  local repo_with_project="$1"
  local project repo
  IFS='/' read -r project repo <<< "$repo_with_project"

  # with_tag=true helps return tag metadata; sorted latest first by push_time
  local url="projects/${PROJECT}/repositories/${repo}/artifacts?with_tag=true&sort=-push_time&page=1&page_size=${ARTIFACTS_PER_REPO}"
# projects/onboarding/repositories/nagios/artifacts
  local resp
  resp="$(API "$url")"
  [[ -z "$resp" || "$resp" == "null" ]] && return 0

  # Transform into normalized NDJSON
  # We try to surface multi-arch “signal”:
  #  - .manifest_media_type: detect index (multi-arch) vs single manifest
  #  - .references[].platform.architecture if Harbor exposes sub-manifests
  echo "$resp" | jq -c --arg repo "$repo" '
    .[] |
    {
      repository: $repo,
      digest: (.digest // ""),
      push_time: (.push_time // ""),
      pull_time: (.pull_time // ""),
      size: (.size // 0),
      type: (.type // ""),  # e.g., IMAGE
      manifest_media_type: (.manifest_media_type // ""),
      tags: ( [ (.tags // [])[] | .name ] ),
      # Try to list platforms if this is a manifest list/index
      platforms: ( [ (.references // [])[]?.platform? | "\(.os // "unknown")/\(.architecture // "unknown")" ] | unique )
    }'
}

# ---------- Main ----------
NDJSON="${OUT_DIR}/harbor_artifacts_${PROJECT}.ndjson"
CSV="${OUT_DIR}/harbor_artifacts_${PROJECT}.csv"

: > "$NDJSON"

log INFO "Discovering repositories for project '${PROJECT}' from ${HARBOR_API}"
repos="$(fetch_all_repositories)"
if [[ -z "$repos" ]]; then
  log WARN "No repositories found in project '${PROJECT}'."
else
  repo_count="$(printf "%s\n" "$repos" | wc -l | tr -d ' ')"
  log INFO "Found ${repo_count} repositories. Collecting up to ${ARTIFACTS_PER_REPO} artifacts per repo..."
fi

# Iterate repos and collect artifacts
while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  log INFO "Processing repo: ${repo}"
  discover_repo_artifacts "$repo" >> "$NDJSON" || true
done <<< "$repos"

# Build CSV from NDJSON
# CSV columns: repository,digest,push_time,manifest_media_type,tags_csv,platforms_csv,size
echo "repository,digest,push_time,manifest_media_type,tags,platforms,size" > "$CSV"
if [[ -s "$NDJSON" ]]; then
  jq -r '
    . |
    [
      (.repository // ""),
      (.digest // ""),
      (.push_time // ""),
      (.manifest_media_type // ""),
      ((.tags // []) | join("|")),
      ((.platforms // []) | join("|")),
      (.size // 0)
    ] | @csv
  ' "$NDJSON" >> "$CSV"
fi

log INFO "Discovery complete."
log INFO "NDJSON: $NDJSON"
log INFO "CSV:    $CSV"
