#!/bin/bash
#
# Script: supervisorctl_restart.sh
# Purpose: Check status of supervisorctl programs, restart them, and check status after
# Usage: ./supervisorctl_restart.sh "prog1,prog2,prog3"
# Written By: Vishal

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 \"prog1, prog2,...\""
    exit 1
fi

# Split by comma, trim spaces
IFS=',' read -r -a RAW_PROGRAMS <<< "$1"

# Trim whitespace from each element
PROGRAMS=()
for prog in "${RAW_PROGRAMS[@]}"; do
    prog="$(echo "$prog" | xargs)"   # xargs trims whitespace
    [[ -n "$prog" ]] && PROGRAMS+=("$prog")
done

echo "${PROGRAMS[@]}"

echo "==== Checking status BEFORE restart ===="
for prog in "${PROGRAMS[@]}"; do
    echo "--- $prog ---"
    supervisorctl status "$prog" || echo "Program $prog not found"
done

echo
echo "==== Restarting programs ===="
for prog in "${PROGRAMS[@]}"; do
    echo "--- Restarting $prog ---"
    supervisorctl restart "$prog" || echo "Failed to restart $prog"
done

# Small wait before checking status
sleep 3

echo
echo "==== Checking status AFTER restart ===="
for prog in "${PROGRAMS[@]}"; do
    echo "--- $prog ---"
    supervisorctl status "$prog" || echo "Program $prog not found"
done
