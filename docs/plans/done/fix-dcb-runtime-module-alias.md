# Fix DCB Runtime: Module Alias + AppSync Routing

## Problem

The new compiled ReScript entry points (`DcbCommandTopicEntryPoint.res`, `AutomationSliceEntryPoint.res`, `StateViewSliceEntryPoint.res`) replaced the hand-written JS handler factories (`DcbCommandTopicHandlerFactory.mjs`, etc.) in commit `6cb31332`. Two issues prevent DCB commands from working at runtime:

### Issue 1: `DcbEventLogSpec` is undefined at runtime

Every DCB slice file declares:

```rescript
module DcbEventLogSpec = CatalogEventLog
```

ReScript compiles this module alias to `let DcbEventLogSpec;` (undefined) in ESM output when the alias is not referenced as a value within the same file. The type-level reference (`DcbEventLogSpec.event` in `reduce`/`decide` signatures) is resolved at compile time and doesn't generate runtime code.

At **deploy time** this is fine — the functor call in `CatalogPlugin_Aws.res` correctly passes `DcbEventLogSpec: CatalogEventLog$CatalogPlugin` (the actual imported module). But at **runtime**, the entry point dynamically imports the slice module (e.g., `AddProduct.res.mjs`) and reads `specModule.DcbEventLogSpec.eventSchema`, which crashes.

The old hand-written factory had `const dcbEventLogSpec = patchedSpec.DcbEventLogSpec || patchedSpec;` as a fallback — but this doesn't actually work either, because `patchedSpec` (the slice module) also doesn't export `eventSchema`. The `open CatalogEventLog` in the source only brings type constructors into scope; ESM doesn't re-export opened values.

**Affected entry points:**
- `DcbCommandTopicEntryPoint.res` — accesses `patchedSpec.DcbEventLogSpec.eventSchema`
- `AutomationSliceEntryPoint.res` — accesses `specModule.DcbEventLogSpec.eventSchema`
- `StateViewSliceEntryPoint.res` — accesses `specModule.DcbEventLogSpec.eventSchema`

### Issue 2: DCB entry point missing AppSync resolver routing

The `DcbCommandTopicEntryPoint` only handles SQS events (`event.Records`). But AppSync resolvers invoke the same Lambda directly with `{command, arguments, meta}` format (no `Records`). The aggregate entry point handles both routes; the DCB one doesn't.

The old factory had a comment: `// CommandGenerator (AppSync direct invocation) not yet reconstructed in bundled mode.` — this was a known gap.

---

## Options

### Option A: Fix in example/user files (explicit module definition)

Change every `module DcbEventLogSpec = SomeEventLog` to an explicit module body:

```rescript
// Before:
module DcbEventLogSpec = CatalogEventLog

// After:
module DcbEventLogSpec = {
  type event = CatalogEventLog.event
  let eventSchema = CatalogEventLog.eventSchema
}
```

This forces the compiler to emit a proper runtime assignment:

```js
// Before: let DcbEventLogSpec;              (undefined)
// After:  let DcbEventLogSpec = { eventSchema: CatalogEventLog$CatalogPlugin.eventSchema };
```

**Pros:**
- No framework changes needed — the entry points read `DcbEventLogSpec.eventSchema` correctly
- The fix is in the same file as the declaration, making the workaround visible
- Works for all entry points automatically (DcbCommandTopic, AutomationSlice, StateViewSlice)

**Cons:**
- Affects every slice file across all examples (41 files in hybrid + dcb examples, and all future user projects)
- Breaks the idiomatic `module M = X` pattern shown in the spec module type's docstring
- Users must know to use the verbose form — if they follow the docstring example they'll hit the same bug
- The `StateChangeSlice.Spec` docstring and all documentation show `module DcbEventLogSpec = CatalogEventLog`

**If chosen:** Also update the `StateChangeSlice.Spec`, `StateViewSlice.Spec`, `AutomationSlice.Spec`, `InboundTranslationSlice.Spec`, and `OutboundTranslationSlice.Spec` docstrings to show the explicit form, and update the platform-and-plugin-guide.

### Option B: Fix in framework (add event log module path to HANDLER_CONFIG)

Thread the DCB event log module path through the deploy-time config so the entry point can import it directly.

1. Add `let moduleUrl: string = %raw(\`import.meta.url\`)` to `CatalogEventLog.res` / `OrderingEventLog.res`
2. Add `moduleUrl` to the `DcbEventLog.Spec` module type
3. In `DcbEventLog_Builder.Make` (AWS), register the event log module path via `PluginRuntime_Builder.registerDcbEventLogModulePath`
4. Add `dcbEventLogModule` field to `HANDLER_CONFIG` JSON in `PluginRuntime_Builder.forDcbCommandTopic`
5. In all three entry points, import the event log module once and patch `DcbEventLogSpec` on each spec

**Pros:**
- Users keep the idiomatic `module DcbEventLogSpec = CatalogEventLog` pattern
- Fix is invisible to user code — framework handles it
- Single source of truth: the event log module path comes from the module itself

**Cons:**
- Adds `moduleUrl` requirement to `DcbEventLog.Spec` module type (minor breaking change to spec packages)
- More moving parts: config plumbing through `PluginRuntime_Builder` → `HANDLER_CONFIG` → entry point
- Must patch all three entry points + the `PluginRuntime_Builder`

### Option C: Fix in `patchSpecId` (runtime reconstruction)

Extend the existing `patchSpecId` helper to also reconstruct `DcbEventLogSpec` from the spec module's own imports, without adding config fields.

The key insight: the spec module's compiled JS *does* import `CatalogEventLog` when `eventSchema` is referenced (even transitively through `@s.matches(DcbTag.string)`). We can detect and extract it.

In practice, this is fragile — the import may or may not exist depending on whether the compiler tree-shakes it. **Not recommended.**

---

## AppSync Routing (Issue 2)

Regardless of which option is chosen for Issue 1, the entry point needs AppSync routing. The implementation:

1. Add `event.command` and `event.arguments` accessors to the entry point
2. Detect AppSync events: `(event.command, event.arguments)` both present
3. For AppSync events: build command JSON from arguments, publish to SQS via `publishJsons`, return `msgId`
4. For SQS events: existing handling

The aggregate entry point (`AggregateEntryPoint.res`) has this pattern already and can serve as reference (lines 286–333).

---

## Recommendation

**Option B** is the cleanest long-term fix. Adding `moduleUrl` to `DcbEventLog.Spec` is a small, well-motivated addition (it mirrors `StateChangeSlice.Spec` which already has `moduleUrl`). The framework should handle runtime quirks, not user code.

However, **Option A** is faster to implement and doesn't require framework API changes. It could serve as an interim fix while Option B is implemented.

---

## Files to change

### Option A
- 16 slice files in `examples/online-shop-hybrid/`
- 25 slice files in `examples/online-shop-dcb/`
- 5 spec module type docstrings in `reventless/reventless-spec/src/components/`
- `docs/guides/platform-and-plugin-guide.md`

### Option B
- `reventless/reventless-spec/src/components/DcbEventLog.res` — add `moduleUrl` to Spec
- `examples/online-shop-hybrid/catalog/src/Plugin/CatalogEventLog.res` — add `moduleUrl`
- `examples/online-shop-hybrid/ordering/src/Plugin/OrderingEventLog.res` — add `moduleUrl`
- `examples/online-shop-dcb/catalog/src/Plugin/CatalogEventLog.res` — add `moduleUrl`
- `examples/online-shop-dcb/ordering/src/Plugin/OrderingEventLog.res` — add `moduleUrl`
- `reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res` — register + serialize path
- `reventless/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.res` — import + patch
- `reventless/reventless-aws/src/adapter/Runtime/AutomationSliceEntryPoint.res` — import + patch
- `reventless/reventless-aws/src/adapter/Runtime/StateViewSliceEntryPoint.res` — import + patch

### AppSync routing (both options)
- `reventless/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.res` — add AppSync route
