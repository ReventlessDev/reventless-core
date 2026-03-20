# Fix: Lambda Functions Redeploy Every Run

## Status: DONE (2026-03-20)

## Problem

Every `pulumi up` redeploys all Lambda functions even when application code has not changed. This wastes deployment time and causes unnecessary Lambda cold starts.

## Root Causes

Two issues combined to cause non-deterministic Lambda deployments:

### 1. FileAsset serializes file paths into Pulumi state

Pulumi's `FileAsset` serializes the **file path** (not just content) into its state. Our bundling code (`Util_Bundle.mjs`) creates a new temp directory on every run via `fs.mkdtempSync()`, so the path changes each time:

```
Run 1: /tmp/reventless-bundle-abc123/index.mjs
Run 2: /tmp/reventless-bundle-xyz789/index.mjs
```

### 2. esbuild embeds entry point path as a comment in output

Even after switching to `StringAsset` (which serializes content, not paths), bundles were still non-deterministic. Investigation revealed that esbuild embeds a comment with the **entry point's relative path** in its output:

```javascript
// ../../../../../private/var/folders/.../reventless-bundle-xNre3a/wrapper.mjs
```

Since `mkdtempSync` generates a random suffix each run, this comment differs every time, producing different content and different hashes.

## Implementation

### Step 1: Switch FileAsset to StringAsset

**File**: `reventless/reventless-aws/src/util/Util_Bundle.mjs`

Replaced `FileAsset` with `StringAsset` in `buildAndArchive()`. Read the bundled output into a string and pass it to `StringAsset`, which serializes content directly (path-independent).

### Step 2: Stable temp directories

**File**: `reventless/reventless-aws/src/util/Util_Bundle.mjs`

Replaced `fs.mkdtempSync()` with `stableTmpDir()` — a helper that creates a temp directory named by a SHA-256 hash of the wrapper code content. Same input always produces the same directory name, so esbuild's path comment is deterministic.

### Step 3: Add sourceCodeHash

**Files**: `reventless/reventless-aws/src/util/Util_Bundle.mjs`, `reventless/reventless-aws/src/util/Util_Bundle.res`, `rescript/rescript-pulumi-aws/src/Lambda/Lambda.res`

- `buildAndArchive()` now returns `{ code, sourceCodeHash }` where `sourceCodeHash` is a base64 SHA-256 of the bundled code
- Added `sourceCodeHash` binding to `Lambda.Function.args`
- All 4 Lambda call sites pass `sourceCodeHash` to explicitly tell Pulumi when code has changed

### Step 4: Clean up temp directories

`buildAndArchive()` calls `fs.rmSync(tmpDir, { recursive: true, force: true })` after reading the bundled code into memory.

## Files Changed

| File | Change |
|------|--------|
| `reventless/reventless-aws/src/util/Util_Bundle.mjs` | `FileAsset` → `StringAsset`, stable temp dirs, hash computation, temp cleanup |
| `reventless/reventless-aws/src/util/Util_Bundle.res` | Return type changed to `bundle` record with `code` + `sourceCodeHash` |
| `rescript/rescript-pulumi-aws/src/Lambda/Lambda.res` | Add `sourceCodeHash` to `Function.args` |
| `reventless/reventless-aws/src/util/Util_DeadLetterQueue.res` | Destructure bundle, pass `sourceCodeHash` |
| `reventless/reventless-aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res` | Destructure bundle, pass `sourceCodeHash` (2 call sites) |
| `reventless/reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate.res` | Destructure bundle, pass `sourceCodeHash` |

## Verification

Confirmed deterministic output locally: calling `bundleEntryPoint` twice with identical input produces identical hashes. Pending `pulumi preview --diff` verification in a deployed environment.
