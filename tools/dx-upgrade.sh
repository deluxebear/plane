#!/usr/bin/env bash
# Upgrade the fork to a new upstream stable tag.
#
#   tools/dx-upgrade.sh <new-tag> [--old <old-tag>] [--allow-rc] [--force]
#
# Model: every custom feature lives on its own `feat/*` branch, based on an
# upstream stable tag. For each new upstream tag this script
#   1. rebases every feat/* branch from the old tag onto the new tag, and
#   2. rebuilds the throw-away integration branch dx/<new-tag> = <new-tag> + all feat/*.
#
# Re-running after resolving a conflict is safe: branches already on the new tag are skipped.
set -euo pipefail

# Re-exec from a temp copy: this file lives on a branch that the script checks out and rewrites.
if [ -z "${DX_UPGRADE_REEXEC:-}" ]; then
  tmp="$(mktemp)"
  cp "$0" "$tmp"
  DX_UPGRADE_REEXEC=1 exec bash "$tmp" "$@"
fi

NEW_TAG=""
OLD_TAG=""
ALLOW_RC=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --old) OLD_TAG="${2:?--old needs a tag}"; shift 2 ;;
    --allow-rc) ALLOW_RC=1; shift ;;
    --force) FORCE=1; shift ;;
    -h | --help) echo "usage: tools/dx-upgrade.sh <new-tag> [--old <old-tag>] [--allow-rc] [--force]"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) NEW_TAG="$1"; shift ;;
  esac
done
[ -n "$NEW_TAG" ] || { echo "usage: tools/dx-upgrade.sh <new-tag> [--old <old-tag>] [--allow-rc] [--force]" >&2; exit 2; }

die() { echo "error: $*" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
git remote get-url upstream >/dev/null 2>&1 || die "no 'upstream' remote (git remote add upstream https://github.com/makeplane/plane.git)"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "working tree is not clean"
[ ! -d "$(git rev-parse --git-path rebase-merge)" ] && [ ! -d "$(git rev-parse --git-path rebase-apply)" ] \
  || die "a rebase is in progress; finish it (git rebase --continue) and re-run"

git fetch upstream --tags --quiet
git rev-parse -q --verify "refs/tags/$NEW_TAG^{commit}" >/dev/null || die "tag $NEW_TAG not found on upstream"
if [[ "$NEW_TAG" == *-rc* || "$NEW_TAG" == *-beta* || "$NEW_TAG" == *-alpha* ]] && [ "$ALLOW_RC" -ne 1 ]; then
  die "$NEW_TAG is a pre-release; pass --allow-rc to use it anyway"
fi

# Old base = newest existing dx/<tag> branch other than the target, unless given.
if [ -z "$OLD_TAG" ]; then
  OLD_TAG="$(git for-each-ref --format='%(refname:short)' 'refs/heads/dx/v*' \
    | sed 's#^dx/##' | grep -vxF "$NEW_TAG" | sort -V | tail -1 || true)"
fi
[ -n "$OLD_TAG" ] || die "cannot detect the old tag; pass --old <tag>"
git rev-parse -q --verify "refs/tags/$OLD_TAG^{commit}" >/dev/null || die "old tag $OLD_TAG not found"
[ "$OLD_TAG" != "$NEW_TAG" ] || die "old and new tag are the same"

mapfile -t FEATS < <(git for-each-ref --format='%(refname:short)' 'refs/heads/feat/*' | sort)
echo "upgrade: $OLD_TAG -> $NEW_TAG, features: ${#FEATS[@]}"

for f in "${FEATS[@]}"; do
  if git merge-base --is-ancestor "$NEW_TAG" "$f"; then
    echo "  skip   $f (already on $NEW_TAG)"
    continue
  fi
  if ! git merge-base --is-ancestor "$OLD_TAG" "$f"; then
    die "$f is not based on $OLD_TAG; rebase it manually onto $OLD_TAG first"
  fi
  echo "  rebase $f"
  if ! git rebase --onto "$NEW_TAG" "$OLD_TAG" "$f"; then
    echo
    echo "Conflict while rebasing $f. Resolve it, 'git rebase --continue',"
    echo "then re-run: tools/dx-upgrade.sh $NEW_TAG --old $OLD_TAG"
    exit 1
  fi
done

DX="dx/$NEW_TAG"
if git rev-parse -q --verify "refs/heads/$DX" >/dev/null; then
  [ "$FORCE" -eq 1 ] || die "$DX already exists; pass --force to rebuild it"
fi
git checkout -q -B "$DX" "$NEW_TAG"
for f in "${FEATS[@]}"; do
  echo "  merge  $f"
  if ! git merge --no-ff --no-edit -m "merge: $f" "$f"; then
    echo
    echo "Conflict between features while building $DX (merging $f)."
    echo "Resolve and commit, then merge the remaining feat/* branches by hand."
    exit 1
  fi
done

cat <<EOF

done: $DX = $NEW_TAG + ${#FEATS[@]} feature(s)
next:
  - bump version on $DX only (package.json files + apps/api/pyproject.toml, then 'cd apps/api && uv lock')
  - check migrations (cd apps/api && uv run python manage.py makemigrations --check)
  - pnpm install && pnpm check
  - git push --force-with-lease origin 'feat/*' && git push origin $DX
EOF
