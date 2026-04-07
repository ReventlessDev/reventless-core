# Plan: AWS Lambda Layer Per-Branch Naming

**Date:** 2026-04-06  
**Status:** Complete  
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
- [x] Push to `alpha` branch
- [x] Workflow ran and published `reventless-aws-alpha:1` (then `:2` after subsequent push)
- [x] `.github/layer-arn-alpha.txt` committed back with the new ARN

### Step 4 — Redeploy the alpha environment

- [x] Platform stack deployed on 2026-04-06 — platform Lambdas reference `reventless-aws-alpha:1`
- [x] Plugin deploy bug fixed (plugin job read `layer-arn.txt` instead of `layer-arn-alpha.txt`)
- [x] Confirm plugin Lambdas (catalog, ordering) reference `reventless-aws-alpha:2` after redeploy — all active alpha functions confirmed on `:2`

### Step 5 — Delete all existing `reventless-aws` versions

> Only run this after Step 4 is confirmed working. No running environment should reference the old ARNs at this point.

- [x] All 72 versions of `reventless-aws` deleted
- [x] Verified: zero versions remain

### Step 6 — Clear the old ARN file

- [x] `.github/layer-arn.txt` was already empty (no action needed)

---

## Verification Checklist

- [x] `reventless-aws-alpha` layer exists in AWS Lambda console (eu-west-1) — at `:2`
- [x] Alpha environment Lambdas reference `reventless-aws-alpha:2`
- [x] `reventless-aws` has zero versions in AWS Lambda console
- [x] `.github/layer-arn.txt` is empty
- [x] `.github/layer-arn-alpha.txt` contains the active alpha ARN (`reventless-aws-alpha:2`)
- [x] Subsequent push produced `reventless-aws-alpha:2` ✓

---

## Beta / Production (future)

- **Beta:** Repeat Steps 3–4 for `beta` branch when beta testing begins. `reventless-aws-beta:1` will be published automatically on the first layer build from `beta`.
- **Production:** First `main` layer build publishes `reventless-aws:1` — the clean start.
