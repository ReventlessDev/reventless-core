# Plan: keep admin aggregate mutations off the split-mode domain server

## Shipped — duplicate SDL crash

A split-mode local platform that calls `makePlatform` and then
`deployPlugin(~apiTarget=Platform)` crashed at `startServers()`:

```
Error: Field "Mutation.Platform_Plugin_Activate" can only be defined once.
Field "Mutation.Platform_Plugin_Deactivate" can only be defined once.
Field "Mutation.Platform_Plugin_Retire" can only be defined once.
```

Two writers put the Plugin aggregate's lifecycle fields on the platform server:

1. `makePlatform` registers `Platform_AdminApi.baseFragment`, which includes
   `PluginBaseFragment.pluginAggregateMutationEntries` (the lifecycle trio),
   guarded per server by `adminRegisteredServers`.
2. `deployPlugin` constructs the admin again (`Admin.construct` →
   `Plugin_Helpers.registerAdminAggregateMutations` →
   `CommandGeneratorResolvers_GraphQL.register`), which lands the same three
   fields on the same platform server — outside that guard.

**Fix:** `GraphQL_ServerInstance.registerMutations` dedupes SDL fields by field
name (first definition wins), mirroring the resolver dict where a repeat
registration overwrites by key. This makes any double-registration path safe,
not just this one. Verified: the platform schema carries each lifecycle field
exactly once and lifecycle dispatch still reaches the aggregate.

## Open — the trio also lands on the domain server

`makePlatform` calls `Admin.construct` **before** it sets
`currentDeployTarget := Platform`. The aggregate-mutation hook resolves its
target server at call time, so the lifecycle mutations are also registered on
the **domain** GraphQL server (port 4000).

**Severity: a dead field, not an auth bypass.** Measured on a running split-mode
platform, calling `Platform_Plugin_Deactivate` on port 4000 with no credentials
returns `INTERNAL_SERVER_ERROR`, and the server logs

```
Cannot return null for non-nullable field Mutation.Platform_Plugin_Deactivate.  [GraphQL:Domain]
```

`handlerRefs` is a module-level dict keyed by field name, so the later
platform-side `register` replaces the entry; the domain resolver closes over the
**first** ref, which nothing ever binds. It returns `null` into a non-nullable
field and always fails. So the impact is a polluted domain subgraph with three
permanently broken fields — not privileged access. (Port 4001 is separately
protected by `PlatformGraphQL_Server.wrapAdmin`, which returns
`UNAUTHORIZED: requires group "Admin"` — confirmed.)

## Rejected approach — do not just move the target switch

The obvious fix, hoisting `currentDeployTarget := Platform` above
`Admin.construct` (restoring it to `Domain` afterwards, since plugin builds
below need it), was implemented and **fails at startup**:

```
Cross-plugin schema merge failed (mirrors AWS MERGE_FAILED):
Unknown type "Platform_UiFragment". Did you mean "Platform_UiFragmentFilter"?
```

The admin's `UiFragmentsViewSlice` splits across the two mechanisms: its GraphQL
**type** registrations follow `currentDeployTarget` (via `resolveTargetGraphQL`),
while its **query** registrations follow `StateViewSliceMaker.QueryDbResolvers.serverRef`
— which `makePlatform` never sets, so they stay on the domain server. Flipping
only the target moves the types to the platform server and leaves the queries
behind referencing a type that no longer exists there. Any real fix has to keep
a slice's types and queries on the same server.

## Suggested direction

Route the *admin aggregate* mutation registration to the platform server without
moving the rest of `Admin.construct`'s registrations — e.g. give
`registerAdminAggregateMutations` an explicit target (it is already a distinct
entry point from the plugin-aggregate path), or thread the admin's server
through `Platform_Admin.construct` rather than relying on ambient
`currentDeployTarget`. Verify with:

- split mode: no `Platform_*` mutation fields in the domain schema; the platform
  schema carries each exactly once; lifecycle dispatch still works.
- the domain schema keeps `Platform_UiFragment*` queries **and** their types
  together (the failure mode above).
- unified mode unchanged (single server; the dedup collapses the overlap).

## Out of scope

- AWS adapter: AppSync gates `Platform_*` fields with
  `@aws_auth(cognito_groups: ["Admin"])` at the schema level; this is a
  local-adapter issue.
