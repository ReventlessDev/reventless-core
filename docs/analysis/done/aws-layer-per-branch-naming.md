# AWS Lambda Layer Per-Branch Naming Analysis

**Date:** 2026-04-06  
**Status:** Analysis  
**Context:** Evaluating whether to rename the Lambda layer from `reventless-aws` to branch-scoped names (`reventless-aws-alpha`, `reventless-aws-beta`, `reventless-aws`)

---

## Current State

The Lambda layer is published to AWS Lambda under a single name: **`reventless-aws`**.

- Current ARN: `arn:aws:lambda:eu-west-1:<account-id>:layer:reventless-aws:72`
- Layer name is hardcoded in `.github/workflows/build-lambda-layer.yml`
- The ARN of the latest publish is stored in `.github/layer-arn.txt` and committed to the repo
- All three branches (`alpha`, `beta`, `main`) push to this same name — each push creates a new version number (`:72`, `:73`, etc.)
- The ARN is picked up by `deploy-reventless-aws.yml` from `layer-arn.txt` and passed as `REVENTLESS_LAYER_ARN` to Pulumi deployments

---

## The Proposal

Rename the layer based on branch:

| Branch | Layer Name |
|--------|-----------|
| `alpha` | `reventless-aws-alpha` |
| `beta` | `reventless-aws-beta` |
| `main` | `reventless-aws` |

Each branch would maintain its own independent layer version counter and its own ARN file (e.g., `layer-arn-alpha.txt`, `layer-arn-beta.txt`, `layer-arn.txt`).

---

## Advantages

### 1. Branch isolation — no accidental cross-environment contamination
Currently, a layer push from `alpha` increments the shared version counter and overwrites `layer-arn.txt`. If a beta or production deployment runs shortly after an alpha push, it may pick up an alpha-built layer. With named layers, alpha, beta, and prod each have their own independent version series.

### 2. Simpler rollback
Each environment can be rolled back independently to any prior version within its own layer. Rolling back `alpha` to layer version `:71` doesn't affect what `:production` uses.

### 3. Auditability
The AWS Lambda console shows all versions per layer name. With a single shared name, version `:72` might be from `alpha` or `main` — indistinguishable. With named layers, all versions of `reventless-aws-alpha` are clearly alpha builds.

### 4. Parallel development safety
If `beta` and `alpha` are active simultaneously, their layer builds don't interfere. Today, whichever branch pushes last owns `layer-arn.txt`.

### 5. Cleaner CI semantics
The deploy workflow reads the ARN from a branch-specific file. The correct file is always authoritative for that environment, removing any timing dependency between branches.

---

## Consequences and Risks

### 1. Existing deployments still reference the old layer name
Any Pulumi stack currently running with `REVENTLESS_LAYER_ARN` pointing to an `reventless-aws:NN` ARN will not automatically migrate. Old environments must be redeployed to pick up the renamed layer.

### 2. Three separate ARN files must be managed
- `layer-arn-alpha.txt`
- `layer-arn-beta.txt`
- `layer-arn.txt` (production / main)

Each must be committed back to the repo by CI. If a branch-specific push fails partway through, its ARN file may be stale. This is a minor operational concern but worth tracking.

### 3. AWS cost: three layer name slots instead of one
AWS Lambda layers are free to publish but each named layer has its own independent version limit (10,000 versions per layer name per region — this is not a practical concern). Storage costs are per version × size; with three names, old versions of all three accumulate. Mitigation: add periodic cleanup of old layer versions.

### 4. Initial migration effort
- Update `build-lambda-layer.yml` to determine branch name and set layer name dynamically
- Add branch-specific ARN file read/write logic in `deploy-reventless-aws.yml`
- Any existing platform stacks must be re-deployed once after migration

### 5. Slightly more complex workflow YAML
The workflow currently has a hardcoded `reventless-aws` layer name. Making it dynamic requires a `steps.determine-layer-name.outputs.layer_name` pattern (see "What Has To Change" below), which adds a few lines of YAML.

---

## What Has To Change

### `.github/workflows/build-lambda-layer.yml`

**Determine layer name from branch:**
```yaml
- name: Determine layer name
  id: layer-name
  run: |
    case "${{ github.ref_name }}" in
      main) echo "name=reventless-aws" >> $GITHUB_OUTPUT ;;
      beta) echo "name=reventless-aws-beta" >> $GITHUB_OUTPUT ;;
      alpha) echo "name=reventless-aws-alpha" >> $GITHUB_OUTPUT ;;
      *) echo "name=reventless-aws-alpha" >> $GITHUB_OUTPUT ;;
    esac
```

**Use in publish step:**
```yaml
- name: Publish Lambda layer
  run: |
    LAYER_ARN=$(aws lambda publish-layer-version \
      --layer-name ${{ steps.layer-name.outputs.name }} \
      --description "reventless-aws v${{ env.REVENTLESS_AWS_VERSION }}" \
      ...)
```

**Write to branch-specific ARN file:**
```yaml
- name: Store layer ARN
  run: |
    case "${{ github.ref_name }}" in
      main)  ARN_FILE=".github/layer-arn.txt" ;;
      beta)  ARN_FILE=".github/layer-arn-beta.txt" ;;
      alpha) ARN_FILE=".github/layer-arn-alpha.txt" ;;
      *)     ARN_FILE=".github/layer-arn-alpha.txt" ;;
    esac
    echo "$LAYER_ARN" > "$ARN_FILE"
    git add "$ARN_FILE"
    git commit -m "chore(ci): update layer ARN for ${{ github.ref_name }}"
    git push
```

### `.github/workflows/deploy-reventless-aws.yml`

**Read from branch-specific ARN file:**
```yaml
- name: Resolve layer ARN
  id: layer-arn
  run: |
    case "${{ github.ref_name }}" in
      main)  ARN_FILE=".github/layer-arn.txt" ;;
      beta)  ARN_FILE=".github/layer-arn-beta.txt" ;;
      alpha) ARN_FILE=".github/layer-arn-alpha.txt" ;;
      *)     ARN_FILE=".github/layer-arn-alpha.txt" ;;
    esac
    if [ -n "${{ inputs.layer-arn }}" ]; then
      echo "arn=${{ inputs.layer-arn }}" >> $GITHUB_OUTPUT
    elif [ -f "$ARN_FILE" ]; then
      echo "arn=$(cat $ARN_FILE)" >> $GITHUB_OUTPUT
    fi
```

### New ARN files to commit
- `.github/layer-arn-alpha.txt` — initially contains current `layer-arn.txt` value
- `.github/layer-arn-beta.txt` — initially same or empty
- `.github/layer-arn.txt` — keep for production (`main`), unchanged

---

## Recommendation

**Yes — this is a good idea.** The single shared layer name is a latent environment contamination risk and makes rollback more complex than it needs to be. The migration cost is low (one workflow YAML update, three ARN files) and the operational benefit compounds over time as alpha/beta/production diverge.

**Suggested migration sequence:**
1. Update `build-lambda-layer.yml` to use dynamic layer name and branch-specific ARN file
2. Update `deploy-reventless-aws.yml` to read from branch-specific ARN file
3. Push to `alpha` — this will publish the first `reventless-aws-alpha` version and write its ARN to `.github/layer-arn-alpha.txt`
4. Redeploy the alpha environment to confirm it picks up the new ARN
5. Delete all 72 existing `reventless-aws` versions (see "Cleanup" section below)
6. Clear `.github/layer-arn.txt` (the old ARN is now invalid)
7. Repeat for `beta` when ready
8. `reventless-aws` (production / `main`) starts fresh from version `:1` on the first `main` layer build

**Not recommended:** sharing the ARN file (e.g., always writing to `layer-arn.txt`) while using distinct layer names — that would still cause cross-branch ARN collisions in the file.

---

## Cleanup of Existing `reventless-aws` Versions

**Decision:** All 72 existing `reventless-aws` layer versions will be fully deleted from AWS as part of the migration. The `reventless-aws` name will be vacated and reused for `main`/production going forward.

### Why delete rather than keep
- The old versions are all alpha/development builds — no production environment depends on them
- Keeping them creates confusion: version `:72` in the new scheme would be a production release, but `:1–:72` would be alpha history under the same name
- Clean break makes version numbers meaningful: `reventless-aws:1` will be the first proper production release

### How to delete all versions

AWS does not support deleting all versions of a layer in one call. Each version must be deleted individually.

**One-liner to delete all 72 versions:**
```bash
for v in $(seq 1 72); do
  aws lambda delete-layer-version \
    --layer-name reventless-aws \
    --version-number $v \
    --region eu-west-1
done
```

Or using the AWS CLI to list and delete dynamically (safer if version count is uncertain):
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

### Timing

Delete the old versions **after** the alpha environment has been successfully redeployed against `reventless-aws-alpha`. This ensures there is no gap where a running environment references a deleted ARN.

Sequence:
1. Deploy `reventless-aws-alpha` (first new layer)
2. Redeploy alpha environment → confirm it uses the new ARN
3. Delete all `reventless-aws` versions (the 72 old ones)
4. Proceed with beta and main migrations

### Note on `.github/layer-arn.txt`

After deletion, update `.github/layer-arn.txt` to be empty or remove it — it currently holds `arn:aws:lambda:eu-west-1:<account-id>:layer:reventless-aws:72` which will be invalid after cleanup. The production ARN file will be repopulated when the first `main` layer build runs.

---

## Open Questions

- Should the `reventless-aws` (production) layer only be built from `main`, or also from release tags? Currently any push to `main` with changes in `reventless-layer-builder/` triggers a build — this is fine for production.
- If a manual `workflow_dispatch` is triggered from a feature branch, which layer name should it use? Current proposal defaults to `alpha`.
