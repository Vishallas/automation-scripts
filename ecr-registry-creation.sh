#!/usr/bin/env bash
set -euo pipefail

usage() {
  logging "FATAL" "Usage: $0 --region <aws-region> --file <repos.txt>"
  exit 1
}

log_file_path=""
log_file_dir=""

logging() {

    if [[ -n $log_file_path && -f $log_file_path ]]; then
        echo -e "$(date +"%Y-%m-%dT%H:%M:%S%z") | [$1]           | $2" >> $log_file_path
    elif [[ -n $log_file_path && -n $log_file_dir ]]; then
        mkdir -p $log_file_dir
        touch $log_file_path
        echo -e "$(date +"%Y-%m-%dT%H:%M:%S%z") | [$1]           | $2" >> $log_file_path
    else
        echo -e "$(date +"%Y-%m-%dT%H:%M:%S%z") | [$1]           | $2"
    fi
}

# Default values
AWS_REGION=""
REPO_NAME_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --file)
      REPO_NAME_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

# Validate inputs
if [[ -z "$AWS_REGION" || -z "$REPO_NAME_FILE" ]]; then
  logging "ERROR" "Missing required arguments."
  usage
fi

if [[ ! -f "$REPO_NAME_FILE" ]]; then
  logging "FATAL" "Repo list file '$REPO_NAME_FILE' not found!"
  exit 1
fi

while read -r REPO_NAME; do
  [[ -z "$REPO_NAME" ]] && continue

  logging "INFO" "Creating repository: $REPO_NAME"

  # Step 1: Create repo with IMMUTABLE mode
  aws ecr create-repository \
    --repository-name "$REPO_NAME" \
    --image-tag-mutability IMMUTABLE_WITH_EXCLUSION \
    --image-tag-mutability-exclusion-filters "filterType=WILDCARD,filter=latest" \
    --region "$AWS_REGION" \
    >/dev/null
  
  logging "INFO" "Repo $REPO_NAME created with immutable tags, except 'latest' which is mutable."
done < "$REPO_NAME_FILE"
