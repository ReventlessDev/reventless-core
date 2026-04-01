# Plugin Built Hook

## Context

The SDK needs to know when a plugin is built and what components it contains, so it can automatically register the plugin in the `PluginRegistry` (in-memory) and write `plugin-info:*` entries to DynamoDB (AWS). Currently there's no way for external code to observe plugin construction — the component metadata is only available inside `Plugin_Builder.construct`.

Core already fires hooks during plugin construction (`schemaTypeRegistrationHook`, `mcpSchemaRegistrationHook`). This plan adds one more: `onPluginBuiltHook`, which fires after all components are built with a plain-data summary of the plugin's name, version, and components.

---

## Status

| Step | Description | Status |
|------|-------------|--------|
| 1 | Add `pluginBuiltInfo` type to `Plugin_Helpers` | done |
| 2 | Add `onPluginBuiltHook` register/clear API to `Plugin_Helpers` | done |
| 3 | Fire the hook in `Plugin_Builder.construct` | done |
| 4 | Update `callback-hooks-and-adapter-wrapping.md` guide | done |
| 5 | Validate core builds + tests pass | done |

---

## Step 1 — Add `pluginBuiltInfo` type

**File:** `reventless-core/src/components/Plugin/Plugin_Helpers.res`

```rescript
type pluginBuiltComponent = {
  name: string,
  kind: string,
}

type pluginBuiltInfo = {
  name: string,
  version: string,
  components: array<pluginBuiltComponent>,
}
```

Plain data — no `Pulumi.Output.t` wrapping. This is consumed by both in-memory (immediate `PluginRegistry.register`) and AWS (DynamoDB write inside `Output.apply`). Using `string` for `kind` instead of `ComponentType.t` avoids coupling to the infra package from the callback type.

## Step 2 — Add register/clear API

**File:** `reventless-core/src/components/Plugin/Plugin_Helpers.res`

```rescript
let onPluginBuiltHook: ref<option<pluginBuiltInfo => unit>> = ref(None)

let registerOnPluginBuilt = (hook: pluginBuiltInfo => unit) => {
  onPluginBuiltHook.contents = Some(hook)
}

let clearOnPluginBuilt = () => {
  onPluginBuiltHook.contents = None
}
```

Same pattern as `commandInterceptorHook`, `queryInterceptorHook`, `beforePublishHook`, `afterPublishHook`. Single slot — the SDK fills it with a function that handles platform-specific registration.

## Step 3 — Fire the hook in `Plugin_Builder.construct`

**File:** `reventless-core/src/components/Plugin/Plugin_Builder.res`

Fire after all component dicts are populated, before the `Output.apply` block (around line 200). At this point, the component dict keys (which ARE the component names) are available synchronously.

```rescript
// After all components are built, before Output.apply
switch Plugin_Helpers.onPluginBuiltHook.contents {
| Some(hook) =>
  let mapNames = (d: dict<_>, kind: string) =>
    d->Dict.keysToArray->Array.map(name => ({Plugin_Helpers.name, kind}: Plugin_Helpers.pluginBuiltComponent))
  hook({
    name,
    version,
    components: [
      ...mapNames(aggregatesDict, "Aggregate"),
      ...mapNames(readModelsDict, "ReadModel"),
      ...mapNames(stateChangeSlicesDict, "StateChangeSlice"),
      ...mapNames(stateViewSlicesDict, "StateViewSlice"),
      ...mapNames(automationSlicesDict, "AutomationSlice"),
      ...mapNames(extensionPointsDict, "ExtensionPoint"),
      ...mapNames(outboundTranslationSlicesDict, "OutboundTranslationSlice"),
      ...mapNames(inboundTranslationSlicesDict, "InboundTranslationSlice"),
    ],
  })
| None => ()
}
```

The exact dict variable names depend on what `Plugin_Builder.construct` calls them internally — verify during implementation by reading the actual source.

## Step 4 — Update guide

**File:** `docs/guides/callback-hooks-and-adapter-wrapping.md`

Add a section for the new hook:

### Plugin Built

**Module:** `Plugin_Helpers`

```rescript
type pluginBuiltComponent = { name: string, kind: string }
type pluginBuiltInfo = { name: string, version: string, components: array<pluginBuiltComponent> }

let registerOnPluginBuilt: (pluginBuiltInfo => unit) => unit
let clearOnPluginBuilt: unit => unit
```

Called after a plugin's components are fully constructed. Receives the plugin name, version, and a list of all component names and kinds. Fires synchronously during `Plugin_Builder.construct`, before `makePlatform` or `deployPlugin` returns.

**Where it fires:** `Plugin_Builder.construct` — after all component builders have run and the component dicts are populated.

**Use cases:** plugin metadata registration, deploy-time metadata persistence, admin dashboard population.

Also update the Processing Flow diagram to show the hook.

## Step 5 — Validate

Build core and run all tests. The hook is additive — no existing code breaks. When unset (`None`), plugin construction is unchanged.
