# Plan: Adapter-seam generalizations for third-party runtime backends

**Status**: Draft (2026-07-03)
**Nature**: batched hardening plan, all items small and additive (or renames
with deprecation aliases — cheap while the module types are pre-1.0). Touches
`reventless-core/src/adapter/` and `reventless-infra/src/adapter/`. Two
existing backends (`reventless-aws`, `reventless-local`) must build unchanged
apart from mechanical alias adoption.

## Motivation

The generic adapter layer leaks AWS *vocabulary* — field names, enum
variants, doc prose — though never AWS *types*. Two in-repo backends tolerate
this; a third backend on different infrastructure (e.g. container
orchestration + relational storage + message streams) has to map its concepts
through Lambda/DynamoDB/SQS-shaped names. Each item below removes one such
leak. None is blocking (documented mappings work today); together they make
the seam honest about being provider-neutral.

## Items

### S1 — `commandHandlerConfig` provider extension

`reventless-core/src/adapter/Runtime/Runtime.res:78-96`: the config record
carries Lambda-shaped fields (`reservedConcurrency`, `sqsBatchSize`,
`ephemeralStorageMb`, `logRetentionDays`). Keep them (documented per-provider
mapping: a backend honors what maps, ignores the rest — the posture
`reventless-local` already documents), and add an escape hatch:

```rescript
providerConfig?: dict<JSON.t>   // provider-specific knobs, namespaced by the
                                // backend package; core never interprets it
```

so a backend can accept e.g. replica bounds or node placement per component
without core learning that vocabulary. Document the mapping table for the
existing fields in the module's doc comments while there.

### S2 — `resourceInfo` variants for relational/streaming stores

`reventless-infra/src/adapter/Adapter.res:2-6`: today
`StorageKeys({partitionKey, sortKey})` (key-value-shaped) and
`ApiResolver({typeName, fieldName})` (GraphQL-generic — fine as is). Add:

```rescript
| SqlTable({schema: string, table: string})
| MessageSubject({subject: string})
```

Additive; deploy-hook payload consumers must treat unknown variants
tolerantly (see S5). Also document that `StorageKeys.partitionKey` reads
generically as "primary key column" where a backend prefers reuse over the
new variant.

### S3 — Naming neutralization (rename + deprecation alias)

- `~publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>` →
  `~publishToAggregatesTargets` in
  `reventless-core/src/adapter/Runtime/ExtensionPointRuntime_Builder.res`,
  `ExtensionPointRuntime_Builder_PerExtensionPoint.res`,
  `TaskRuntime_Builder.res`, `TaskRuntime_Builder_PerBucket.res`. A "target"
  is whatever the channel's `publishJsons` addresses (queue URL, subject,
  in-process topic). Keep the old labeled argument as a deprecated alias for
  one release train.
- Sweep AWS-flavored doc comments in the generic layer ("AWS resource tags",
  Cognito-specific examples in `Auth_Adapter.res`) to neutral wording with
  provider examples listed as examples, not definitions.
- `schedulerConfig` (`TaskRuntime_Builder.res:5-13`) is already URN-generic —
  verify wording only, no rename.

### S4 — Document the handler packaging contract (docs only)

Handler entry metadata already flows portably as ESM module paths
(`~specModulePath`, `~callbackModulePath`, entry-point re-export stubs, the
`HANDLER_CONFIG` env indirection). Write this down as the stable contract in
the adapter docs: *a runtime environment receives an ESM module path
exporting `handler`, plus a JSON config dict; how it packages and transports
those (zip, image, in-process import) is the backend's concern.* Backends
build on this being stable; today it is convention, not documentation.

### S5 — Deploy-hook payload neutrality (coordination item)

The deploy-hook payload work (see `docs/plans/deploy-hook-dcb-slice-schema-parity.md`
and the deploy-hook parity thread) should define payload field names
provider-neutrally from the start — no `queueUrl`/`tableName`/ARN-shaped
keys in the generic payload; provider specifics ride in the free-form
`configuration` dict. This plan contributes the S2 variants and a review of
the payload schema; the substantive work stays in the deploy-hook plan.
Consumers must tolerate unknown `resourceInfo` variants and `service`/
`resourceType` strings (they are free-form by design).

## Phasing

| Item | Order | Class |
|---|---|---|
| S1 providerConfig | any | Additive |
| S2 resourceInfo variants | before S5 review | Additive |
| S3 renames + doc sweep | any | Rename w/ alias |
| S4 packaging-contract docs | any | Docs |
| S5 deploy-hook payload review | with the deploy-hook plan | Coordination |

All five can land as one release-train batch; S1/S2 are the ones a
third-party backend consumes programmatically, so they front the queue.

## Non-goals

- A full generic redesign of `commandHandlerConfig` (breaking the published
  API for cosmetics is not worth it; the escape hatch suffices).
- Removing Pulumi from the seam (it *is* the seam: every signature threads
  `Pulumi.Output.t` deliberately).
- Un-parameterizing `Platform.T` or touching the topology builders — they
  are provider-neutral already.

## Risks

- Deprecation aliases on labeled arguments are awkward in ReScript (no
  argument-level deprecation) — if an alias proves impractical, do a clean
  rename in one train with a loud CHANGELOG entry instead; both consumers
  are in-repo or version-pinned.
- S2's new variants ripple into any exhaustive `switch` over `resourceInfo`;
  grep all matches in-repo and fix in the same change.
