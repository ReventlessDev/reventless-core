# Extension Plugin Naming + Auto-Merge

## Status: DONE

## Goal

Each plugin should have at most **one Extension per foreign ExtensionPoint**. That single Extension is named after the plugin (not the delegate). Multiple mappings for the same EP within one plugin are automatically merged into a single Extension component.

**Current naming:** `EP.name ++ "." ++ Delegate.name` (set by Extension_Builder, where Mappings.name = Delegate.name)
**Target naming:** `EP.name ++ "." ++ pluginName` (e.g., `"Catalog.Products.Ordering"`)

---

## Problem

1. **Naming**: Extension component names derive from delegate names (`ProductDemand`, `CatalogProduct`). From the EP's perspective, it sees "a subscription from the Ordering plugin" — the delegate is an implementation detail. The name should be the plugin name.

2. **No merge enforcement**: A plugin can accidentally create multiple Extensions for the same EP (e.g., two separate `Extension.Make` calls for the same EP), resulting in duplicate EventTopic subscriptions. The framework should merge these automatically.

3. **Plugin name unavailable at Make time**: `Platform.Extension.Make` runs before `Plugin.make`, which is where the plugin name is known. The name can't be set at Make time.

---

## Approach: Deferred naming via Plugin.make

### Key Insight

`Extension_Builder.Make` constructs the component name as `Spec.name ++ "." ++ Mappings.name`. The `Mappings.name` is currently set at `Platform.Extension.Make` time. Instead, the naming should be deferred to `Plugin.make`, which knows the plugin name.

### Option A: Plugin.make sets extension names post-construction

`Plugin.make` already receives `~extensions: array<module(Extension.T)>`. After constructing each Extension, it could:
1. Group extensions by `extensionPointName` (from `Extension.outputs`)
2. Validate: error if multiple extensions share the same EP (they should have been merged with Make2/Make3)
3. Override the component name to `pluginName`

**Problem**: Pulumi component names are set at construction time inside `Component.make()`. Renaming after construction would require changing the component resource name, which isn't straightforward.

### Option B: Pass plugin name into Extension.Make

Add `~pluginName` to `Extension.Make`:
```rescript
module Make: (
  Mapping: ExtensionMapping.Mapping,
  Config: {let pluginName: string},
) => Extension.T
```

The developer passes `{let pluginName = "Catalog"}` and the framework uses it for naming. Make2/Make3 do the same.

**Problem**: Duplicates the plugin name (also passed to `Plugin.make`). But it's simple and explicit.

### Option C: Plugin.make accepts mappings instead of pre-built extensions

Replace `~extensions: array<module(Extension.T)>` with a new parameter:
```rescript
~extensionMappings: array<module(ExtensionMapping.CompiledMapping)>
```

`Plugin.make` internally:
1. Groups compiled mappings by EP
2. Merges mappings with the same EP into one Extension (combining their mappings arrays)
3. Names each Extension as `pluginName`
4. Builds the Extension component

**Requires**: A new `CompiledMapping` module type — a type-erased, pre-compiled mapping that carries its EP name but hides the concrete EP types. This is essentially what `ExtensionMapping.T` already is, but wrapped to be packable in a heterogeneous array.

**Problem**: The `~extensions` array currently holds first-class modules of different EP types. Packing `ExtensionMapping.T` modules with different `ExtensionPoint` types into one array requires existential typing — the same trick already used for `Extension.T`.

### Option D (Recommended): Extension.Make produces a "blueprint", Plugin.make builds

Split Extension creation into two phases:

**Phase 1** — `Platform.Extension.Make(Mapping)` returns a **blueprint** (not a component):
```rescript
module type Blueprint = {
  module Spec: ExtensionMapping.Spec
  let name: string  // delegate name (for Make2/Make3: "D1+D2")
  let moduleUrl: string
  let mappings: array<module(ExtensionMapping.T with module ExtensionPoint := Spec)>
}
```

This is essentially the current `ExtensionMapping.Mappings` type — but exposed as the return value instead of hidden inside Make.

**Phase 2** — `Plugin.make` receives blueprints:
```rescript
~extensions: array<module(Extension.Blueprint)>
```

Inside Plugin.make:
1. Group blueprints by `Spec.name` (the EP name)
2. Merge blueprints with the same EP: combine their `mappings` arrays
3. Set `name = pluginName` on the merged blueprint
4. Call `Extension_Builder.Make(Spec, Mappings)` to build the actual component

**Advantages**:
- Automatic merge — the developer can pass individual per-delegate blueprints
- Plugin name is used for all extensions automatically
- No duplicate naming
- Make2/Make3 become unnecessary (but can stay for explicit control)

**Challenge**: Merging blueprints with different `Spec` paths. Two blueprints for the same EP have `Spec = CatalogSpec.ProductsExtensionPoint` — same concrete module. But after passing through functors, the compiler may not know they're the same. The merge would need to happen at the `module(Blueprint)` level where `Spec` is existentially hidden.

This means the merge must be done with runtime checks (comparing `Spec.name`) and `Obj.magic` for the type cast — similar to how first-class module arrays work elsewhere in the framework.

---

## Sequencing

1. **Phase 1**: Add validation in Plugin.make — error if two extensions share the same EP name. This catches accidental duplicates immediately, with no API change.

2. **Phase 2**: Implement Option D — split Extension into blueprint + build. Update Plugin.make to accept blueprints, auto-merge, and set plugin name.

3. **Phase 3**: Remove Extension.Make2/Make3/MakeMulti — auto-merge makes them unnecessary.

---

## Files to change

### Phase 1 (validation only)
- `reventless-core/src/components/Plugin/Plugin_Helpers.res` — add duplicate EP check in `createExtensions`

### Phase 2 (blueprint + auto-merge)
- `reventless-infra/src/types/ExtensionMapping.res` — export `Mappings` as `Blueprint` (or add a `Blueprint` type alias)
- `reventless-infra/src/components/Extension.res` — add `Blueprint` module type
- `reventless-infra/src/types/Platform.res` — `Extension.Make` returns Blueprint, not T
- `reventless-aws/src/Platform.res` — update Extension.Make
- `reventless-in-memory/src/Platform.res` — update Extension.Make
- `reventless-core/src/components/Plugin/Plugin_Builder.res` — accept blueprints, group/merge/build
- `reventless-core/src/components/Plugin/Plugin_Helpers.res` — merge logic
- All example plugin files — pass blueprints instead of pre-built extensions

---

## Risk

- **Blueprint merge type safety**: Merging blueprints with runtime EP name matching requires `Obj.magic`. This is safe because the EP name uniquely identifies the type, but it bypasses the compiler.
- **Backward compatibility**: Changing `~extensions` from `array<module(Extension.T)>` to `array<module(Extension.Blueprint)>` is a breaking change. Could be mitigated by accepting both during a transition period.
- **MakeMulti compatibility**: `MakeMulti` and the admin `PluginConnectExtension_Builder` build Extensions directly (not blueprints). These would need an escape hatch or different parameter.
