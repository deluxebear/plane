# Fork workflow: custom features on top of upstream stable releases

This fork (`origin` = deluxebear/plane) tracks upstream (`upstream` = makeplane/plane). Custom work is kept as
independent feature branches that are carried forward onto each new upstream **stable** tag.

## Branches

| Branch            | Purpose                                                                                     |
| ----------------- | ------------------------------------------------------------------------------------------- |
| `feat/*`          | One custom feature each. Based directly on an upstream stable tag. Rebased on every upgrade. |
| `dx/<tag>`        | Throw-away integration branch = `<tag>` + all `feat/*`. This is what gets built/deployed.   |
| `feat/dx-tooling` | Holds `tools/dx-upgrade.sh` and this document; treated like any other feature.              |
| `preview`         | Plain mirror of `upstream/preview`. Never develop on it, never base features on it.         |

Only stable tags (`vX.Y.Z`) are used as a base. Never `-rc`, `preview` or `canary`.

## Rules

1. New feature: `git checkout -b feat/<name> dx/<current-tag>` (or the tag itself). Keep commits limited to that feature.
2. A feature branch is based on the tag, not on another feature. If features depend on each other, merge them into one branch.
3. Never commit on `dx/*`, except the version bump described below. They are regenerated on every upgrade.
4. Prefer new files, directories and Django apps. Touch upstream files as little as possible, with small, focused hooks.
5. Do not change dependency versions away from upstream. On lockfile conflicts take upstream's side and regenerate
   (`pnpm install`, `cd apps/api && uv lock`).
6. Do not edit shared docs such as `AGENTS.md` for fork-only notes; put them here.

## Upgrading to a new upstream stable tag

```bash
git fetch upstream --tags
tools/dx-upgrade.sh vX.Y.Z          # --old <tag> to override detection, --force to rebuild dx/vX.Y.Z
```

The script rebases every `feat/*` from the old tag onto the new tag, then rebuilds `dx/vX.Y.Z` by merging them all.
On a conflict it stops. Resolve it, run `git rebase --continue`, then run the same command again; branches that are
already on the new tag are skipped. `rerere` is enabled, so a conflict resolved once is resolved automatically next time.

After the script finishes, on `dx/vX.Y.Z`:

1. Bump the version to `X.Y.Z-dx.N` in every `package.json` and in `apps/api/pyproject.toml` (they must match), then
   `cd apps/api && uv lock`. Commit on `dx/*` only, never on a feature branch.
2. Check migrations: `cd apps/api && uv run python manage.py makemigrations --check`. If an upstream migration now
   collides with a feature's migration number, renumber or merge it on the feature branch and re-run the script.
3. `pnpm install && pnpm check`, and run the API tests (see `AGENTS.md`).
4. Push: `git push --force-with-lease origin 'feat/*'` and `git push origin dx/vX.Y.Z`, then tag `vX.Y.Z-dx.N`.

## One-time setup (new clone)

```bash
git remote add upstream https://github.com/makeplane/plane.git
git config rerere.enabled true
git config rerere.autoupdate true
git fetch upstream --tags
```

## Picking up an upstream fix before the next stable release

```bash
git log vX.Y.Z..upstream/preview --grep='SECUR'     # find the fix
git checkout -b feat/upstream-fix-<name> dx/vX.Y.Z
git cherry-pick <sha>
```

Treat it as a feature branch. After the next upstream release it becomes empty; delete it once rebase drops its commits.

## CI

`.github/workflows/build-branch.yml` pushes images to the upstream Docker Hub namespace and must be pointed at this
fork's registry before it is used here. `check-version.yml` only runs on PRs into `master` and does not affect this flow.
