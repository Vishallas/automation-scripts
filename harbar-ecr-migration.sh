#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Harbor Discovery + Optional Migration to AWS ECR
# ------------------------------------------------------------------------------
# - Default: Discover artifacts and generate NDJSON + CSV reports
# - Migration Mode: If a CSV file is provided as --migrate-from <file>,
#   pull+push all listed artifacts into AWS ECR, preserving multi-arch manifests.
#
# Requirements: curl, jq, docker (with buildx + login to both Harbor & ECR)
# ------------------------------------------------------------------------------

usage() {
  cat <<'EOF'

Required (discovery mode):

Usage: harbar-ecr-migration.sh --project <project> --token <token>

  --project       Harbor project name
  --token         Harbor base64 token (user:pass -> base64)

Required (migration mode):

Usage: harbar-ecr-migration.sh --migrate-from <file.csv> --harbar-user <username> ----harbor-pass <password> --ecr <ecr-registry-prefix>

  --migrate-from  CSV file produced by discovery (enables migration mode)
  --harbar-user   Harbor Username to pull the images
  --harbor-pass   Harbor Password to pull the images
  --ecr           AWS ECR registry (e.g., 1234567890.dkr.ecr.us-east-1.amazonaws.com)

Optional:
  --artifacts     Number of artifacts per repo (default 5)


  -h, --help      Show help
EOF
}

# ---------- Defaults ----------
PROJECT="${PROJECT:-}"
HARBOR_HOST="https://registry.mydbops.com"

HARBOR_TOKEN="${HARBOR_TOKEN:-}"
ARTIFACTS_PER_REPO=5
PAGE_SIZE=100
OUT_DIR="./harbor-reports"
MIGRATE_FILE=""
AWS_REGION=""
ECR_REGISTRY=""
HARBOR_USER=""
HARBOR_PASS=""
HARBOR_API="${HARBOR_API:-$HARBOR_HOST/api/v2.0}"

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)      PROJECT="$2"; shift 2 ;;
    --token)        HARBOR_TOKEN="$2"; shift 2 ;;
    --artifacts)    ARTIFACTS_PER_REPO="$2"; shift 2 ;;
    --out)          OUT_DIR="$2"; shift 2 ;;
    --migrate-from) MIGRATE_FILE="$2"; shift 2 ;;
    --ecr)          ECR_REGISTRY="$2"; shift 2 ;;
    --harbor-user)  HARBOR_USER="$2"; shift 2 ;;
    --harbor-pass)  HARBOR_PASS="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# ---------- Tools ----------
command -v jq >/dev/null || { echo "ERROR: jq not found in PATH"; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not found in PATH"; exit 1; }

TS() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() { echo -e "$(TS) | [$1] | $2"; }

API() {
  local url="$1"
  [[ "$url" != http*://* ]] && url="${HARBOR_API%/}/$url"
  curl -sS -H "authorization: Basic ${HARBOR_TOKEN}" -H "Accept: application/json" "$url"
}

# ---------- Discovery Mode ----------
discover_mode() {
  mkdir -p "$OUT_DIR"
  local NDJSON="${OUT_DIR}/harbor_artifacts_${PROJECT}.ndjson"
  local CSV="${OUT_DIR}/harbor_artifacts_${PROJECT}.csv"
  : > "$NDJSON"

  log INFO "Discovering repositories for project '${PROJECT}'"
  repos="$(API "projects/${PROJECT}/repositories?page=1&page_size=${PAGE_SIZE}" | jq -r '.[].name')"

  for repo_with_project in $repos; do
    IFS='/' read -r project repo <<< "$repo_with_project"
    log INFO "Processing repo: ${repo}"
    API "projects/${PROJECT}/repositories/${repo}/artifacts?with_tag=true&sort=-push_time&page=1&page_size=${ARTIFACTS_PER_REPO}" \
    | jq -c --arg repo "$repo" --arg project "$PROJECT" \
        ' .[] | {
          project: $project,
          repository: $repo,
          digest: (.digest // ""),
          push_time: (.push_time // ""),
          manifest_media_type: (.manifest_media_type // ""),
          tags: ( [ (.tags // [])[] | .name ] ),
          platforms: ( [ (.references // [])[]?.platform? | "\(.os // "unknown")/\(.architecture // "unknown")" ] | unique )
        }'  >> "$NDJSON"
  done
  # Build CSV
  echo "project,repository,digest,push_time,manifest_media_type,tags,platforms" > "$CSV"
  jq -r '[.project,.repository,.digest,.push_time,.manifest_media_type,((.tags//[])|join("|")),((.platforms//[])|join("|"))] | @csv' "$NDJSON" >> "$CSV"

  log INFO "Discovery complete."
  log INFO "NDJSON: $NDJSON"
  log INFO "CSV:    $CSV"
}

# ---------- Migration Mode ----------
migrate_mode() {
  [[ -z "$MIGRATE_FILE" || ! -f "$MIGRATE_FILE" ]] && { log ERROR "Migration file not found: $MIGRATE_FILE"; exit 1; }
  [[ -z "$ECR_REGISTRY" ]] && { log ERROR "ECR registry/region required"; exit 1; }
  
  region=$(echo "$ECR_REGISTRY" | cut -d'.' -f4)
  log INFO "Logging into AWS ECR..."
#   aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

  log INFO "Starting migration using $MIGRATE_FILE"
  tail -n +2 "$MIGRATE_FILE" | while IFS=, read -r project repo digest push_time media_type tags platforms; do
    repo=$(echo "$repo" | tr -d '"')
    project=$(echo "$project" | tr -d '"')
    tags=$(echo "$tags" | tr -d '"')
    digest=$(echo "$digest" | tr -d '"')

    # IFS='/' read -r project repository <<< "$repo"

    harbor_image="registry.mydbops.com/${project}/${repo}@${digest}"
    ecr_base="${ECR_REGISTRY}/${repo}"
    [[ -z "$tags" ]] && { log ERROR "TAG Not Found for ${project}/${repo}@${digest}"; exit 1; }
    for tag in $(echo "$tags" | tr '|' ' '); do
      log INFO "Migrating from "$harbor_image" to  ${ecr_base}:${tag}"
    #   oras copy $harbor_image "$ecr_base/$tags" --from-username $HARBOR_USER --from-password $HARBOR_PASS > /dev/null
    done
  done

  log INFO "Migration completed successfully."
}

# ---------- Entrypoint ----------
if [[ -n "$MIGRATE_FILE" || -n $HARBOR_USER || -n "$HARBOR_PASS" ]]; then
  migrate_mode
else
  [[ -z "$PROJECT" || -z "$HARBOR_TOKEN" ]] && { log ERROR "Project and token required for discovery"; usage; exit 1; }
  discover_mode
fi
