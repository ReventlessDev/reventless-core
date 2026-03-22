# Plan: Fix CI/CD Workflow Race Conditions

**Analysis:** [`docs/analysis/ci-workflow-race-conditions.md`](../analysis/ci-workflow-race-conditions.md)
**Status:** Done

## Overview

Fix race conditions in GitHub Actions workflows that cause push rejections, duplicate Lambda Layer builds, and duplicate deployments.

## Steps

### Step 1: Remove duplicate layer build trigger
**File:** `.github/workflows/build-lambda-layer.yml`
**Status:** [x]

Remove the `tags` trigger from the `on.push` section. The Release workflow already explicitly dispatches this workflow via `gh workflow run`, so the tag trigger causes a duplicate run.

Before:
```yaml
on:
  push:
    tags:
      - "@reventlessdev/reventless-aws@*"
    branches: [main, beta, alpha]
    paths:
      - "reventless/reventless-layer-builder/**"
```

After:
```yaml
on:
  push:
    branches: [main, beta, alpha]
    paths:
      - "reventless/reventless-layer-builder/**"
```

This also eliminates issue #3 (layer ARN push race from two concurrent layer builds) and reduces issue #4 (duplicate deploys).

### Step 2: Add retry-with-rebase to Release push
**File:** `.github/workflows/release.yml`
**Status:** [x]

Replace the bare `git push --follow-tags` (line 246) with a retry loop that pulls and rebases before each attempt. This handles the case where another workflow (layer builder, deploy SHA recorder) pushed to the branch during the release process.

Replace:
```yaml
- name: Push version tags and commits
  if: steps.changes.outputs.count != '0'
  run: |
    BRANCH_NAME="${{ steps.prerelease.outputs.branch }}"
    git push --follow-tags origin $BRANCH_NAME
```

With:
```yaml
- name: Push version tags and commits
  if: steps.changes.outputs.count != '0'
  run: |
    BRANCH_NAME="${{ steps.prerelease.outputs.branch }}"
    for i in 1 2 3; do
      git pull --rebase origin "$BRANCH_NAME" && \
      git push --follow-tags origin "$BRANCH_NAME" && exit 0
      echo "Push attempt $i failed, retrying..."
      sleep 5
    done
    echo "All push attempts failed"
    exit 1
```

### Step 3: Add retry-with-rebase to layer ARN push
**File:** `.github/workflows/build-lambda-layer.yml`
**Status:** [x]

Replace the bare `git push` in the "Commit layer ARN to repository" step with a retry loop. Even after Step 1 eliminates duplicate layer builds, the Release workflow's version commits can still cause a push race.

Replace:
```yaml
git push
```

With:
```yaml
BRANCH="${GITHUB_REF#refs/heads/}"
for i in 1 2 3; do
  git pull --rebase origin "$BRANCH" && \
  git push && exit 0
  echo "Push attempt $i failed, retrying..."
  sleep 5
done
echo "All push attempts failed"
exit 1
```

Note: For tag-triggered or dispatch-triggered runs, `GITHUB_REF` may be a tag ref not a branch. Need to handle this — extract the branch from the tag's target or use the default branch. Since Step 1 removes the tag trigger, this simplifies to path-triggered (branch ref) and dispatch (also branch ref).

### Step 4: Improve deploy gate for reventless-aws releases
**File:** `.github/workflows/deploy-online-shop-hybrid.yml`
**Status:** [x]

When the Release workflow triggers a deploy AND that release includes `reventless-aws`, the layer build may not have started yet, so the gate incorrectly allows the deploy. Fix by checking if the triggering release created a `reventless-aws` tag — if so, always defer to the layer build completion trigger.

In the "Decide whether to deploy" step, after the `$TRIGGER == "Release"` check, add:
```yaml
# Check if this release included reventless-aws (which triggers a layer build).
# If so, skip — the layer build completion will trigger a deploy with the fresh ARN.
NEW_TAGS=$(gh api "repos/${{ github.repository }}/actions/runs/${{ github.event.workflow_run.id }}/artifacts" \
  --jq '.artifacts[].name' 2>/dev/null || true)
# Simpler: check the release run's commits for reventless-aws tags
RELEASE_SHA="${{ github.event.workflow_run.head_sha }}"
AWS_TAG=$(git ls-remote --tags origin | grep "$RELEASE_SHA" | grep "reventless-aws@" || true)
if [[ -n "$AWS_TAG" ]]; then
  echo "Release includes reventless-aws — deferring to layer build trigger"
  echo "should-deploy=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
```

Also add `waiting` status to the existing active-build check as a fallback.

### Step 5: Add retry-with-rebase to deploy SHA push
**File:** `.github/workflows/deploy-reventless-aws.yml`
**Status:** [x]

Replace the bare `git push` in the `record-deploy-sha` job with the same retry pattern.

Replace:
```yaml
git push
```

With:
```yaml
BRANCH="${GITHUB_REF#refs/heads/}"
for i in 1 2 3; do
  git pull --rebase origin "$BRANCH" && \
  git push && exit 0
  echo "Push attempt $i failed, retrying..."
  sleep 5
done
echo "All push attempts failed"
exit 1
```

### Step 6: Add `[skip ci]` to lerna version commits
**File:** `.github/workflows/release.yml`
**Status:** [x]

Add `--message` flag to the `lerna version` commands so the version commits include `[skip ci]`, preventing wasteful CI reruns on the version bump commits.

Add to both the prerelease and regular version commands:
```yaml
--message "chore(release): version packages [skip ci]"
```

### Step 7: Remove dead build cache steps from CI
**File:** `.github/workflows/ci.yml`
**Status:** [x]

The cache save/restore steps reference `packages/*/...` paths that don't exist in this monorepo structure (packages live under `reventless/`, `rescript/`, `examples/`). Remove both the "Cache build artifacts" step and the "Restore build artifacts" step since they never cache anything useful. The "Build packages (if cache miss)" step already rebuilds unconditionally as a fallback.

### Step 8: Add alpha to security scan triggers (optional)
**File:** `.github/workflows/security.yml`
**Status:** [x]

Add `alpha` to the push and pull_request branch lists so security scans run on alpha branch pushes too. This is low priority — skip if alpha is intentionally excluded from security scanning.

## Verification

After each step, push to a feature branch and verify:
- CI passes
- No duplicate workflow runs appear in the Actions tab
- For steps 1-5: simulate the race by pushing rapid commits to alpha and confirming no push rejections

After all steps merged to alpha:
- Trigger a release and confirm:
  - Single layer build (not two)
  - Single deploy (not two)
  - No push rejections
  - No extra CI runs from version commits
