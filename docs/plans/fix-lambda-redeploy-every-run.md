# Fix: Lambda Functions Redeploy Every Run

## Problem

Every `pulumi up` redeploys all Lambda functions even when application code has not changed. This wastes deployment time and causes unnecessary Lambda cold starts.

## Root Cause

Pulumi's `FileAsset` serializes the **file path** (not just content) into its state. Our bundling code (`Util_Bundle.mjs`) creates a new temp directory on every run via `fs.mkdtempSync()`, so the path changes each time:

```
Run 1: /tmp/reventless-bundle-abc123/index.mjs
Run 2: /tmp/reventless-bundle-xyz789/index.mjs
```

Even though the bundled content is byte-identical, Pulumi sees a different `FileAsset` path in state and triggers an update.

**Affected code**: `reventless/reventless-aws/src/util/Util_Bundle.mjs` lines 70-72:
```javascript
return new pulumi.asset.AssetArchive({
  "index.mjs": new pulumi.asset.FileAsset(outPath),  // ← path-dependent
});
```

## Diagnosis Step

Before implementing, confirm the root cause:

```bash
pulumi preview --diff
```

Look for changes on Lambda `Function` resources. If the only diff is on the `code` property, this confirms the FileAsset path issue.

## Implementation Plan

### Step 1: Switch FileAsset to StringAsset in Util_Bundle.mjs

**File**: `reventless/reventless-aws/src/util/Util_Bundle.mjs`

Replace `FileAsset` with `StringAsset` in `buildAndArchive()`. Read the bundled output into a string and pass it to `StringAsset`, which serializes content directly (path-independent):

```javascript
function buildAndArchive(wrapperPath) {
  const tmpDir = path.dirname(wrapperPath);
  const outPath = path.join(tmpDir, "index.mjs");

  const result = esbuild.buildSync({
    // ... existing options unchanged ...
  });

  if (result.errors.length > 0) {
    throw new Error(`esbuild bundling failed: ${JSON.stringify(result.errors)}`);
  }

  // Read bundled output as string — StringAsset is path-independent,
  // so Pulumi only sees content changes, not temp directory path changes.
  const bundledCode = fs.readFileSync(outPath, "utf-8");

  return new pulumi.asset.AssetArchive({
    "index.mjs": new pulumi.asset.StringAsset(bundledCode),
  });
}
```

This is a 3-line change: add `readFileSync`, change `FileAsset` → `StringAsset`, swap `outPath` → `bundledCode`.

### Step 2: Add sourceCodeHash to Lambda Function bindings (belt-and-suspenders)

**File**: `rescript/rescript-pulumi-aws/src/Lambda/Lambda.res`

Add `sourceCodeHash` to `Function.args`:

```rescript
type args = {
  handler?: Pulumi.Input.t<string>,
  runtime?: Pulumi.Input.t<string>,
  code?: Pulumi.Input.t<Pulumi.Archive.t>,
  role: Pulumi.Input.t<string>,
  memorySize?: Pulumi.Input.t<int>,
  timeout?: Pulumi.Input.t<int>,
  layers?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  tags?: Pulumi.Input.t<Aws.tags>,
  environment?: Pulumi.Input.t<functionEnvironment>,
  sourceCodeHash?: Pulumi.Input.t<string>,  // ← NEW
}
```

This is optional and doesn't need to be populated immediately — Step 1 alone should fix the issue. But having the binding available allows explicit hash control in the future.

### Step 3: Clean up temp directories

**File**: `reventless/reventless-aws/src/util/Util_Bundle.mjs`

Now that we read the file into memory, we can clean up the temp directory immediately:

```javascript
function buildAndArchive(wrapperPath) {
  const tmpDir = path.dirname(wrapperPath);
  const outPath = path.join(tmpDir, "index.mjs");

  const result = esbuild.buildSync({ /* ... */ });

  if (result.errors.length > 0) {
    throw new Error(`esbuild bundling failed: ${JSON.stringify(result.errors)}`);
  }

  const bundledCode = fs.readFileSync(outPath, "utf-8");

  // Clean up temp directory — content is in memory now
  fs.rmSync(tmpDir, { recursive: true, force: true });

  return new pulumi.asset.AssetArchive({
    "index.mjs": new pulumi.asset.StringAsset(bundledCode),
  });
}
```

### Step 4: Verify the fix

Deploy with no code changes and confirm Lambda functions show **no changes**:

```bash
pulumi preview --diff
```

Expected: Lambda `Function` resources should show no diff when code hasn't changed.

## Files Changed

| File | Change |
|------|--------|
| `reventless/reventless-aws/src/util/Util_Bundle.mjs` | `FileAsset` → `StringAsset` + temp cleanup |
| `rescript/rescript-pulumi-aws/src/Lambda/Lambda.res` | Add `sourceCodeHash` to `Function.args` |

## Risk Assessment

- **Step 1** (StringAsset): Zero risk. `StringAsset` and `FileAsset` produce identical Lambda deployment packages — only the Pulumi state serialization differs. No Lambda runtime behavior changes.
- **Step 2** (sourceCodeHash binding): Zero risk. Adding an optional field to a type. No existing code uses it.
- **Step 3** (temp cleanup): Low risk. Files are only needed during the synchronous esbuild + read sequence, which completes before cleanup.
