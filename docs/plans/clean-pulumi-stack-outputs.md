# Plan: Clean up verbose Pulumi stack outputs ✅

## Problem

`pulumi stack output` shows deeply nested schema objects for every component:

```
Catalog > AddProductSlice > Spec > DcbEventLogSpec > eventSchema > anyOf > ...
```

The user only wants to see infrastructure resources (names, ARNs, IDs), not sury schema definitions.

## Root Cause

Three mechanisms leak schema data into Pulumi stack outputs:

### 1. ESM named exports

ReScript ESM compiles top-level `module Platform = ...` and `module Catalog = ...` as named exports. Pulumi reads ALL ESM named exports as stack outputs. These module objects contain the full component tree including Spec modules with `@schema`-generated sury schemas.

### 2. `Component.setOutputs` property on ComponentResource

`Component.setOutputs` originally set `this.outputs = outputs` directly on the Pulumi ComponentResource instance. Pulumi serializes all Output-typed properties on ComponentResources, leaking internal data.

### 3. Pulumi state persistence

Once verbose outputs are captured in Pulumi's stack state, they persist across deploys even after the code is fixed. The state must be explicitly cleaned.

## Fix (implemented)

### Step 1: Store component outputs in WeakMap ✅

Changed `Component.res` to store outputs and operations in a module-level WeakMap instead of as properties on the ComponentResource instance. This prevents Pulumi from walking component properties.

File: `reventless/reventless-infra/src/components/Component.res`

### Step 2: Override stack outputs via `registerOutputs` on Stack resource ✅

Changed `Pulumi.getOutputs()` to call `registerOutputs(_outputs)` on the Pulumi Stack resource. This overrides Pulumi's auto-captured outputs with only the explicitly `Pulumi.export()`-ed values.

File: `rescript/rescript-pulumi-pulumi/src/Pulumi.res`

### Step 3: Add `index.mjs` wrappers to filter ESM exports ✅

Created `index.mjs` wrapper files for each deploy stack that re-export only `default` from `Main.res.mjs`. This prevents ReScript's top-level module bindings from being visible as ESM named exports.

Files:
- `examples/online-shop-hybrid/catalog-aws/src/index.mjs`
- `examples/online-shop-hybrid/ordering-aws/src/index.mjs`
- `examples/online-shop-hybrid/platform-aws/src/index.mjs`

Updated `Pulumi.yaml` files to point `main:` to `src/index.mjs`.

### Step 4: Clean stale outputs from Pulumi state

Old verbose outputs persist in Pulumi state from previous deploys. One-time cleanup per stack:

```bash
# Export state, remove stale outputs, re-import
pulumi stack export | node -e "
const fs = require('fs');
let d = '';
process.stdin.on('data', c => d += c);
process.stdin.on('end', () => {
  const s = JSON.parse(d);
  const stack = s.deployment.resources.find(r => r.type === 'pulumi:pulumi:Stack');
  if (stack?.outputs) {
    const clean = {};
    if (stack.outputs._interopMeta) clean._interopMeta = stack.outputs._interopMeta;
    // For platform stack, keep apiId, apiRoleArn, extensionPoints
    if (stack.outputs.apiId) clean.apiId = stack.outputs.apiId;
    if (stack.outputs.apiRoleArn) clean.apiRoleArn = stack.outputs.apiRoleArn;
    if (stack.outputs.extensionPoints) clean.extensionPoints = stack.outputs.extensionPoints;
    stack.outputs = clean;
  }
  fs.writeFileSync('/tmp/pulumi-clean-state.json', JSON.stringify(s, null, 2));
});
" && pulumi stack import --file /tmp/pulumi-clean-state.json
```

After cleanup, run `pulumi up` to re-sync. May need to delete orphaned EventSourceMappings that were removed from state.

### Step 5: Verify clean outputs ✅ (catalog stack)

```
Current stack outputs (1):
    OUTPUT        VALUE
    _interopMeta  {"BS_PRIVATE_NESTED_SOME_NONE":0}
```

Remaining: apply same state cleanup to ordering and platform stacks.
