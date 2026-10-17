#!/usr/bin/env bash
# Path-aware checks for epic_loop, run from a worktree root: verify.repoChecks in a ticket worktree,
# merge.checksAfterMerge in the integration worktree. It diffs the branch against its base and runs
# the suite of every project the diff touches. Edit SUITES and BASE_BRANCH for your repository.
#
# Base:
#   integration worktree, branch epic/*   -> BASE_BRANCH, so everything the epic has landed is checked
#   ticket worktree, branch ticket/*      -> the epic/* branch it descends from, so only the
#                                            ticket's own change is checked
#   EPIC_CHECKS_BASE overrides both.
#
# Usage: checks.sh [--dry-run] [--all]
#   --dry-run   print the base and the suites the diff touches; run nothing
#   --all       run every suite
set -uo pipefail

# One entry per project: a path prefix, then the command that runs its suite from the repository root.
SUITES=(
  "web/|cd web && npm ci && npm test"
  "api/|cd api && go test ./..."
)
BASE_BRANCH="${BASE_BRANCH:-main}"

DRY_RUN=false
ALL=false
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=true ;;
    --all) ALL=true ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel)" || exit 2
cd "$ROOT"
BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"

base() {
  local b
  [ -n "${EPIC_CHECKS_BASE:-}" ] && { echo "$EPIC_CHECKS_BASE"; return; }
  case "$BRANCH" in epic/*) echo "$BASE_BRANCH"; return ;; esac
  for b in $(git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads/epic/); do
    git merge-base --is-ancestor "$b" HEAD 2>/dev/null && { echo "$b"; return; }
  done
  echo "$BASE_BRANCH"
}

BASE="$(base)"
CHANGED="$(git diff --name-only "$BASE"...HEAD)"
echo "base $BASE, $(printf '%s\n' "$CHANGED" | grep -c .) changed paths"

rc=0
for s in "${SUITES[@]}"; do
  prefix="${s%%|*}"
  cmd="${s#*|}"
  if $ALL || printf '%s\n' "$CHANGED" | grep -q "^$prefix"; then
    echo "== $prefix  $cmd"
    $DRY_RUN && continue
    ( eval "$cmd" ) || { echo "FAILED: $prefix"; rc=1; }
  fi
done
exit $rc
