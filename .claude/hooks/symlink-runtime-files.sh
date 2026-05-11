#!/usr/bin/env bash
set -euo pipefail

input=$(cat)
worktree_path=$(echo "$input" | jq -r '.worktree_path // empty')

if [ -z "$worktree_path" ]; then
    exit 0
fi

main_repo=$(git worktree list | awk 'NR==1{print $1}')

env_src="$main_repo/backend/.env"
env_dst="$worktree_path/backend/.env"
if [ -f "$env_src" ] && [ ! -e "$env_dst" ]; then
    mkdir -p "$(dirname "$env_dst")"
    ln -s "$env_src" "$env_dst"
fi

pb_src="$main_repo/backend/db-backend/pb_data"
pb_dst="$worktree_path/backend/db-backend/pb_data"
if [ -d "$pb_src" ] && [ ! -e "$pb_dst" ]; then
    mkdir -p "$(dirname "$pb_dst")"
    ln -s "$pb_src" "$pb_dst"
fi
