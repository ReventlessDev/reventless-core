# Plan: AWS Lambda Layer Per-Branch Naming

**Date:** 2026-04-06  
**Status:** Not started  
**Analysis:** [docs/analysis/aws-layer-per-branch-naming.md](../analysis/aws-layer-per-branch-naming.md)

## Goal

Split the single shared `reventless-aws` Lambda layer into three branch-scoped layers:

| Branch | Layer Name |
|--------|-----------|
| `alpha` | `reventless-aws-alpha` |
| `beta`  | `reventless-aws-beta`  |
| `main`  | `reventless-aws`       |

Delete all 72 existing `reventless-aws` versions so the production name starts clean from `:1`.

---

## Steps

### Step 1 — Update `build-lambda-layer.yml`

File: `.github/workflows/build-lambda-layer.yml`

- [x] Add a step to derive the layer name from `github.ref_name`:
  ```yaml
  - name: Determine layer name
    id: layer-name
    run: |
      case "${{ github.ref_name }}" in
        main)  echo "name=reventless-aws" >> $GITHUB_OUTPUT ;;
        beta)  echo "name=reventless-aws-beta" >> $GITHUB_OUTPUT ;;
        alpha) echo "name=reventless-aws-alpha" >> $GITHUB_OUTPUT ;;
        *)     echo "name=reventless-aws-alpha" >> $GITHUB_OUTPUT ;;
      esac
  ```
- [x] Replace the hardcoded `--layer-name reventless-aws` in the publish step with `--layer-name ${{ steps.layer-name.outputs.name }}`
- [x] Update the description to include the branch: `reventless-aws v{VERSION} ({BRANCH})`
- [x] Derive the branch-specific ARN file path and write to it:
  ```yaml
  - name: Determine ARN file
    id: arn-file
    run: |
      case "${{ github.ref_name }}" in
        main)  echo "path=.github/layer-arn.txt" >> $GITHUB_OUTPUT ;;
        beta)  echo "path=.github/layer-arn-beta.txt" >> $GITHUB_OUTPUT ;;
        alpha) echo "path=.github/layer-arn-alpha.txt" >> $GITHUB_OUTPUT ;;
        *)     echo "path=.github/layer-arn-alpha.txt" >> $GITHUB_OUTPUT ;;
      esac
  ```
- [x] Replace the hardcoded `echo "$LAYER_ARN" > .github/layer-arn.txt` with `echo "$LAYER_ARN" > ${{ steps.arn-file.outputs.path }}`
- [x] Update the `git add` to use the dynamic path

### Step 2 — Update `deploy-reventless-aws.yml`

File: `.github/workflows/deploy-reventless-aws.yml`

- [x] Replace the static `layer-arn.txt` read with a branch-aware lookup:
  ```yaml
  - name: Resolve layer ARN file
    id: arn-file
    run: |
      case "${{ github.ref_name }}" in
        main)  echo "path=.github/layer-arn.txt" >> $GITHUB_OUTPUT ;;
        beta)  echo "path=.github/layer-arn-beta.txt" >> $GITHUB_OUTPUT ;;
        alpha) echo "path=.github/layer-arn-alpha.txt" >> $GITHUB_OUTPUT ;;
        *)     echo "path=.github/layer-arn-alpha.txt" >> $GITHUB_OUTPUT ;;
      esac
  ```
- [x] Update the ARN resolution logic to read from `${{ steps.arn-file.outputs.path }}`
- [x] Platform deploy ~line 234 updated ✓
- [x] Plugin deploy ~line 348 was missed in the original change — fixed in `fix(ci): apply branch-scoped layer ARN resolution to plugin deploy step`

### Step 3 — Commit workflow changes and push to `alpha`

- [x] Commit the two workflow file changes with message:
  `feat(ci): use branch-scoped Lambda layer names (alpha/beta/prod)`
- [ ] Push to `alpha` branch
- [ ] Confirm the workflow runs and publishes `reventless-aws-alpha:1`
- [ ] Confirm `.github/layer-arn-alpha.txt` is committed back with the new ARN

### Step 4 — Redeploy the alpha environment

- [x] Platform stack deployed on 2026-04-06 — platform Lambdas reference `reventless-aws-alpha:1`
- [x] Plugin deploy bug fixed (plugin job read `layer-arn.txt` instead of `layer-arn-alpha.txt`)
- [ ] Confirm plugin Lambdas (catalog, ordering) reference `reventless-aws-alpha:1` after redeploy triggered by the bug-fix commit

### Step 5 — Delete all existing `reventless-aws` versions

> Only run this after Step 4 is confirmed working. No running environment should reference the old ARNs at this point.

- [ ] Run the following from a terminal with AWS credentials for `eu-west-1`:
  ```bash
  aws lambda list-layer-versions \
    --layer-name reventless-aws \
    --region eu-west-1 \
    --query 'LayerVersions[*].Version' \
    --output text \
  | tr '\t' '\n' \
  | xargs -I{} aws lambda delete-layer-version \
      --layer-name reventless-aws \
      --version-number {} \
      --region eu-west-1
  ```
- [ ] Verify no versions remain:
  ```bash
  aws lambda list-layer-versions --layer-name reventless-aws --region eu-west-1
  ```

### Step 6 — Clear the old ARN file

- [ ] Clear `.github/layer-arn.txt` (empty the file — do not delete it, the workflow still writes to it for `main`)
- [ ] Commit: `chore(ci): clear stale reventless-aws layer ARN after cleanup`
- [ ] Push to `alpha`

---

## Verification Checklist

- [ ] `reventless-aws-alpha` layer exists in AWS Lambda console (eu-west-1)
- [ ] Alpha environment Lambdas reference the new ARN
- [ ] `reventless-aws` has zero versions in AWS Lambda console
- [ ] `.github/layer-arn.txt` is empty
- [ ] `.github/layer-arn-alpha.txt` contains the active alpha ARN
- [ ] A subsequent push to `alpha` that touches `reventless-layer-builder/` produces `reventless-aws-alpha:2`

---

## Beta / Production (future)

- **Beta:** Repeat Steps 3–4 for `beta` branch when beta testing begins. `reventless-aws-beta:1` will be published automatically on the first layer build from `beta`.
- **Production:** First `main` layer build publishes `reventless-aws:1` — the clean start.
