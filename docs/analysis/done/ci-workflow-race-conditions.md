# CI/CD Workflow Race Conditions & Edge Cases

Analysis of race conditions and edge cases in GitHub Actions workflows that cause push rejections, duplicate builds, and duplicate deployments.

## 1. Release Push Rejection (the reported error)

**Symptom:** `! [rejected] alpha -> alpha (fetch first)` after `git push --follow-tags`

**Root cause:** The Release workflow checks out at `github.sha`, creates version commits + tags locally (`--no-push`), then publishes, then pushes. Between checkout and push, another workflow (or the same workflow on a concurrent commit) can push to the same branch.

Concrete scenarios that cause this:
- **Build Lambda Layer** commits `layer-arn.txt` and pushes to the same branch (line 112 of `build-lambda-layer.yml`).
- **Deploy record-deploy-sha** commits `last-deploy-sha.txt` and pushes (line 492 of `deploy-reventless-aws.yml`).
- A second Release run (rapid pushes to alpha) — although `cancel-in-progress: false` prevents cancellation, both runs can be active if the first is past the concurrency gate by the time the second starts.

**Fix options:**
1. Add `git pull --rebase` before `git push --follow-tags` in the Release workflow.
2. Use a retry loop: pull-rebase-push with up to 3 attempts.
3. Use a dedicated bot branch for automated commits to avoid contention on the release branch.

**Recommended:** Option 2 — a retry loop is the most resilient:
```yaml
- name: Push version tags and commits
  run: |
    BRANCH_NAME="${{ steps.prerelease.outputs.branch }}"
    for i in 1 2 3; do
      git pull --rebase origin "$BRANCH_NAME" && \
      git push --follow-tags origin "$BRANCH_NAME" && break
      echo "Push attempt $i failed, retrying..."
      sleep 5
    done
```

## 2. Duplicate Lambda Layer Builds

**Symptom:** Two layer builds run for the same release.

**Root cause:** `build-lambda-layer.yml` triggers on **two overlapping events** for the same release:

1. **Tag push trigger** (line 5-6): `tags: ["@reventlessdev/reventless-aws@*"]` — fires when `release.yml` pushes the version tag.
2. **`workflow_dispatch` trigger** (line 296-308 of `release.yml`): The release workflow explicitly calls `gh workflow run build-lambda-layer.yml -f version="$VERSION"`.

Both fire for the same version. The concurrency group `build-lambda-layer` with `cancel-in-progress: false` means they queue and both execute.

**Fix:** Remove one trigger. Since the `workflow_dispatch` from Release is more explicit and passes the version, remove the tag trigger:

```yaml
on:
  push:
    branches: [main, beta, alpha]
    paths:
      - "reventless/reventless-layer-builder/**"
  workflow_dispatch:
    inputs:
      version:
        description: "Version of @reventlessdev/reventless-aws to build the layer for"
        required: true
        type: string
```

This preserves the path-triggered build (for layer-builder code changes) and the dispatch from Release, while eliminating the duplicate tag trigger.

## 3. Layer Builder Push Race

**Symptom:** Layer ARN commit push fails if another workflow pushed in between.

**Root cause:** `build-lambda-layer.yml` line 112 does a bare `git push` with no pull/rebase. If the Release workflow pushed version commits, or a second layer build (from issue #2) pushed first, this fails.

**Fix:** Same retry-with-rebase pattern as issue #1:
```yaml
- name: Commit layer ARN to repository
  run: |
    LAYER_ARN="${{ steps.publish.outputs.layer_arn }}"
    echo "$LAYER_ARN" > .github/layer-arn.txt
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add .github/layer-arn.txt
    git commit -m "chore(ci): update Lambda Layer ARN to $LAYER_ARN [skip ci]" || { echo "No change"; exit 0; }
    for i in 1 2 3; do
      git pull --rebase origin "${GITHUB_REF#refs/heads/}" && \
      git push && break
      echo "Push attempt $i failed, retrying..."
      sleep 5
    done
```

## 4. Duplicate Deploy Triggers

**Symptom:** Online Shop Hybrid deploys twice for a single release that includes `reventless-aws`.

**Root cause:** `deploy-online-shop-hybrid.yml` triggers on completion of **both** Release and Build Lambda Layer workflows. The sequence is:

1. Release completes → triggers deploy. The gate job checks for active layer builds. If the layer build hasn't started yet (race window), no active builds are found → deploy proceeds.
2. Layer build completes → triggers another deploy.

Result: two deploys, the first with a stale layer ARN.

**Fix:** The gate logic (lines 54-72) is correct in concept but has a timing gap — the `gh workflow run` dispatch from Release may not have created the layer run yet when the gate checks. Add a short delay or check for "waiting" status too:

```yaml
# Also check for "waiting" runs
WAITING=$(gh run list \
  --repo "${{ github.repository }}" \
  --workflow "Build Lambda Layer" \
  --status waiting \
  --json databaseId --jq 'length')
ACTIVE=$((IN_PROGRESS + QUEUED + WAITING))
```

Alternatively, simplify: if the Release includes a `reventless-aws` tag, always skip the Release-triggered deploy (the layer build will trigger it):

```yaml
# If release included reventless-aws, skip — layer build will trigger deploy
if [[ "$TRIGGER" == "Release" ]]; then
  TAGS=$(gh api "repos/${{ github.repository }}/git/ref/heads/${BRANCH}" \
    --jq '.object.sha' | xargs -I{} gh api "repos/${{ github.repository }}/git/refs/tags" \
    --jq '.[].ref' | grep "reventless-aws@" || true)
  if [[ -n "$TAGS" ]]; then
    echo "Release includes reventless-aws — deferring to layer build"
    echo "should-deploy=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi
fi
```

## 5. Deploy SHA Push Race

**Symptom:** `record-deploy-sha` job fails to push `last-deploy-sha.txt`.

**Root cause:** Same pattern as issues #1 and #3 — bare `git push` on line 492 of `deploy-reventless-aws.yml` with no pull/rebase.

**Fix:** Add pull-rebase retry, same as above.

## 6. CI Triggered by Release Version Commits

**Symptom:** Extra CI runs triggered by lerna version commits.

**Root cause:** `ci.yml` triggers on `push: branches: ["**"]`. When Release pushes version commits + tags, a new CI run fires. The release already waited for CI to pass on the original commit, so this second CI run is wasteful. The doc changelog commit has `[skip ci]` but the lerna version commits don't.

**Impact:** Mostly noise/waste, but combined with issue #1, the CI push can interleave with the Release push timing window.

**Fix:** Add `[skip ci]` to lerna's commit message:
```yaml
npx lerna version ... --message "chore(release): version packages [skip ci]" ...
```

However, this requires `--message` to override lerna's default. Alternatively, filter `.github/` path changes from CI triggers (version commits only touch `CHANGELOG.md` and `package.json` — neither is in `paths-ignore`).

## 7. Build Cache Path Mismatch

**Symptom:** Cache miss on test job → redundant rebuild.

**Root cause:** The cache save (ci.yml line 101-106) saves paths under `packages/*/...` but the actual monorepo structure has packages under `reventless/`, `rescript/`, and `examples/` — not `packages/`. The cache never captures any actual build artifacts.

**Impact:** The "Build packages (if cache miss)" step always runs, which is correct behavior but makes the cache save/restore steps dead code.

**Fix:** Either remove the cache steps (they do nothing) or update the paths to match the actual monorepo layout:
```yaml
path: |
  reventless/*/lib
  rescript/*/lib
  examples/**/lib
```

## 8. Security Scan Not Triggered on Alpha Branch

**Symptom:** Security scan doesn't run on alpha pushes.

**Root cause:** `security.yml` line 6 only triggers on `branches: [main, beta]` — alpha is excluded.

**Impact:** The Release workflow's `wait-on-check-action` uses `check-regexp: "(CI|Security Scan).*"` with `fail-on-no-checks: false`. On alpha, Security Scan simply doesn't run, which is fine for the gate — but means alpha releases skip security scanning entirely.

**Fix:** Add `alpha` to the security scan branch list, or accept this as intentional (alpha = experimental).

## Summary of Issues by Severity

| # | Issue | Severity | Frequency |
|---|-------|----------|-----------|
| 1 | Release push rejection | **High** | Every release when layer/deploy runs concurrently |
| 2 | Duplicate layer builds | **Medium** | Every release that includes reventless-aws |
| 3 | Layer ARN push race | **Medium** | Cascades from #2 |
| 4 | Duplicate deploys | **Medium** | Every reventless-aws release |
| 5 | Deploy SHA push race | **Low** | Only when deploy and another push overlap |
| 6 | Extra CI from version commits | **Low** | Every release (waste, not failure) |
| 7 | Dead cache steps | **Low** | Every CI run (no harm, just noise) |
| 8 | No security scan on alpha | **Low** | Informational |

## Recommended Fix Priority

1. **Fix #2 first** (remove tag trigger from layer build) — this eliminates the root cause of #3 and reduces #4.
2. **Fix #1** (retry-with-rebase on release push) — resolves the reported error.
3. **Fix #3** (retry-with-rebase on layer ARN push) — belt-and-suspenders for remaining edge cases.
4. **Fix #4** (improve gate timing or always defer when reventless-aws is in the release).
5. Fix #5, #6, #7, #8 as low-priority cleanup.
