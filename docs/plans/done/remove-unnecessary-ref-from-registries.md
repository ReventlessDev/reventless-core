# Remove unnecessary `ref` from mutable JS collection registries

## Context

`Dict.t` and `Set.t` from RescriptCore are JS `Object` and `Set` — they mutate in place. Wrapping them in `ref` adds a pointless `.contents` indirection everywhere they're accessed. Two instances were already fixed in `QueryDbStorage_DynamoDbStream` and `EventTopicPublisher_SNS`. Five more remain in `reventless-core`.

The `ref` pattern is only correct when the binding itself is reassigned (e.g. `x := newArray`). None of the targets below do that — they only call `Dict.set`, `Dict.get`, `Set.add`, `Set.has`.

## Files to change

### `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`
- `queryFieldNamesRegistry: ref<dict<Api_Naming.queryNames>>` → `dict<Api_Naming.queryNames>`
- `aggregateMutationFieldsRegistry: ref<dict<array<string>>>` → `dict<array<string>>`
- Remove `.contents` at all call sites (search across entire `src/`)

### `reventless/reventless-core/src/components/Plugin/Plugin_BuiltHook.res`
- `componentSchemaRegistry: ref<dict<pluginDeployedSchema>>` → `dict<pluginDeployedSchema>`
- Remove `.contents` at all call sites

### `reventless/reventless-core/src/components/AutomationSlice/AutomationSlice_Callback.res`
- `todoItems: ref<Dict.t<todoRow>>` → `Dict.t<todoRow>` (closure-local)
- Remove `.contents` within the file

### `reventless/reventless-core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Callback.res`
- `todoItems: ref<Dict.t<todoRow>>` → `Dict.t<todoRow>` (closure-local)
- Remove `.contents` within the file

### `reventless/reventless-core/src/components/InboundTranslationSlice/InboundTranslationSlice_Callback.res`
- `auditLog: ref<Dict.t<auditRow>>` → `Dict.t<auditRow>` (closure-local)
- Remove `.contents` within the file

## Call-site search

```bash
grep -rn "queryFieldNamesRegistry\.contents\|aggregateMutationFieldsRegistry\.contents\|componentSchemaRegistry\.contents" reventless/reventless-core/src/
```

## Out of scope

- `Util_DynamoDb_TableManager.res` `dependencies` — uses `Array.concat` (creates new array), `ref` is needed
- `NodeResolver_AppSync.res` `nodeTypeEntries` — `reset()` reassigns to `[]`, `ref` is needed
- `Plugin_BuiltHook.res` `pluginMetadataRegistry: ref<option<...>>` — option, not a mutable collection

## Verification

```bash
npm run build 2>&1 | grep -E "Warning|warning|error|Error"
```

Zero warnings/errors required.
