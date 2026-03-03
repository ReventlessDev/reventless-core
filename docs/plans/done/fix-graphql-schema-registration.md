# Fix: No GraphQL schema registered for DCB plugins

## Context

When running the example DCB platform (`npm run dev`), the GraphQL server starts with only `_noop` fields — no mutations, no queries in the actual served schema. Diagnostics show 12 query resolvers and 0 mutation resolvers are registered in the global refs, but the running server never picks them up. Two distinct bugs cause this.

## Bug 1: Server starts before plugins register resolvers

**Root cause:** `GraphQL_Server.start()` runs at module-evaluation time inside `Platform.Make()` (line 135 of `Platform.res`) — this fires when `module Platform = ReventlessInMemory.Platform.Make()` is called in `Main.res`, BEFORE any plugins are created. The server builds its SDL from empty registries (all `_noop`). Then plugins construct and register resolvers, but `makePlatform()` is a no-op (lines 127-130) — it never calls `rebuildSchema()`.

**Fix:** Move `GraphQL_Server.start()` out of `Platform.Make()` and into `makePlatform()`, so it runs after all plugins have been built and their resolvers registered.

**File:** `reventless/reventless-in-memory/src/Platform.res`
- Remove `let () = GraphQL_Server.start()` from the module body (line 135)
- Change `makePlatform` from a no-op to call `GraphQL_Server.start()`

## Bug 2: No mutation resolvers for DCB StateChangeSlices

**Root cause:** For aggregate-based plugins, `CommandGenerator_Builder` creates `CommandGeneratorResolvers_GraphQL` which calls `GraphQL_Server.registerMutations()`. For DCB StateChangeSlices, there is NO equivalent. `Plugin_Builder` generates mutation entries in the API schema fragment (lines 151-157), but no corresponding GraphQL resolvers are ever registered. The `createResolvers` helper (line 382) only handles QueryDbs (queries), not mutations.

**Fix:** Register DCB mutation resolvers during `Plugin_Builder.construct()`, inside the `Pulumi.Output.all6.apply` block (where `dcbRuntimeOpt` is invoked at line 410). For each StateChangeSlice, create a resolver that routes the GraphQL mutation call through the DcbCommandTopic's `publishJsons`.

**Key insight:** The existing `CommandGeneratorResolvers_GraphQL` pattern shows how to register mutations — build SDL field strings, create async resolver functions, and call `GraphQL_Server.registerMutations()`. For DCB slices, the resolver needs to call `publishJsons` (from DcbCommandTopic) with the command JSON, similar to how aggregate resolvers call `generateCommand`.

### Implementation steps

**Step 1:** Create `DcbCommandTopicResolvers_GraphQL.res` in `reventless/reventless-in-memory/src/adapter/CommandGenerator/`
- Accept: slice name, command field names, and a `publishJsons` function
- For each field, build SDL: `  ${fieldName}(id: ID, args: String): String`
- For each field, create an async resolver that encodes `{id, args}` as JSON and calls `publishJsons`
- Call `GraphQL_Server.registerMutations(~sdlFields, ~resolvers)`

**Step 2:** Wire the new resolver into `Plugin_Builder.construct()`
- In the DCB branch (lines 92-136), after creating StateChangeSlices, also register mutation resolvers
- This needs to happen where `publishJsons` is available — either synchronously using an adapter call, or inside the Output.apply block
- The simplest approach: call registration synchronously alongside `StateChangeSlice.make()` since the field names and publish function are already available at that point

**Step 3:** Fix timing in `Platform.res`
- Remove `let () = GraphQL_Server.start()` from `Platform.Make()` module body
- In `makePlatform`, call `GraphQL_Server.start()` so it runs after all plugin construction

### Files to modify

| File | Change |
|------|--------|
| `reventless/reventless-in-memory/src/Platform.res` | Move `start()` into `makePlatform()` |
| `reventless/reventless-in-memory/src/adapter/CommandGenerator/DcbCommandTopicResolvers_GraphQL.res` | **New file** — mutation resolver registration for DCB slices |
| `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res` | Wire DCB mutation resolver registration |

### Verification

1. Run `npm run build` — zero warnings
2. Run `npm test` — all existing tests pass
3. Run `cd examples/dcb/example-dcb && npm run dev` — diagnostics should show both mutations AND queries registered, with matching SDL fields and resolvers
4. Open `http://localhost:4000/graphql` — GraphiQL should display the full schema with mutation and query fields
