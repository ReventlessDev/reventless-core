# AppSync deploy-time caller: CommandResult sub-selection

Scope: fix `Util_AppSync_Caller` so the deploy-time mutation dispatcher produces
GraphQL documents that validate against mutations returning the `CommandResult`
union. Close the related surface gap for the reconcile-remove mutations.

## The bug

Every plugin deploy runs the PlatformInspector sync hook, which fires
`Platform_SyncPlatform` / `SyncPlugin` / `SyncComponent` / `SyncResource` /
`SyncExtensionWiring` via `ReventlessAws.Util_AppSync_Caller.sendMutation`.
On AWS these all fail at GraphQL validation:

```
Validation error of type SubSelectionRequired:
Sub selection required for type null of field Platform_SyncComponent
```

The failures are caught (`Promise.catch`, fire-and-forget) so no Pulumi resource
errors — but **no** PlatformInspector StateViewSlice (ResourceInventory,
DeploymentHistory, ExtensionWiring, SchemaHistory, EnvironmentComparison) is
updated on any plugin deploy. This is the concrete mechanism behind the observed
inspector-parity gap.

## Root cause

`Util_AppSync_Caller.buildQuery` emitted a **selectionless** mutation:

```rescript
`mutation { ${mutation}(${args}) }`
```

Every command mutation returns the union
`CommandResult = CommandAccepted | CommandPending | CommandRejected`. GraphQL
requires a sub-selection on any object/union-typed field; without one AppSync's
graphql-java validator rejects the whole document (`SubSelectionRequired`, with
the type rendered as `null`). The helper was written assuming scalar return
types ("call any mutation generically") and never handled object/union returns.
Deterministic — reproduces on every deploy, independent of any schema-push race
or endpoint selection.

## Fix (done)

`reventless-aws/src/util/Util_AppSync_Caller.res` — `buildQuery` and
`sendMutation` gained an optional `~selection` argument defaulting to
`{ __typename }`:

```rescript
let sel = selection == "" ? "" : ` ${selection}`
`mutation { ${mutation}(${args})${sel} }`
```

Design notes:
- **Default `{ __typename }`, not `""`.** The helper has no callers inside core;
  every downstream caller dispatches `CommandResult`-union command mutations.
  Defaulting to a valid sub-selection fixes all callers on a version bump with
  **zero downstream source change** (the arg is optional with a default).
- Scalar-returning mutations (none today) can opt out with `~selection=""`.
- Callers wanting to observe rejection can pass e.g.
  `~selection="{ __typename ... on CommandRejected { reason } }"`.
- `~selection` placed before the required `~variables` / `~variablesDict` so the
  trailing-optional-arg terminator rule is satisfied without a unit param.

Verified: `rescript build` clean (81 modules); emitted JS renders
`mutation { Platform_SyncComponent(...) { __typename } }`.

## Follow-on capability enabled here

`sendMutation` now returns `unit` (fire-and-forget, logs only transport-level
`errors`). A `CommandRejected` result is a *successful* GraphQL response, so it
is currently invisible to callers. A future enhancement can make `sendMutation`
return the decoded `data` (mirroring `sendQuery`) so callers that pass a richer
`~selection` (e.g. `{ __typename ... on CommandRejected { reason } }`) can
observe and act on rejection. Deferred; not required for the validation fix.

## Publishing

Publish `reventless-aws` past this change. Consumers pick it up by bumping the
dependency and recompiling — the optional `~selection` default means no consumer
source edit is required for the validation fix to take effect.
