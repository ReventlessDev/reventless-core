# Backlog: TypeScript Client SDK via Standard Schema v1

**Status:** Backlog — depends on `docs/plans/sury-alpha5-migration.md` Phase 4
**Analysis:** `docs/analysis/typescript-client-feasibility.md` Blocker 1;
`docs/analysis/sury-alpha5-migration.md` (opportunity G);
context from `docs/analysis/rejected/sury-vs-effect-schema.md`.

## Context and motivation

The TypeScript-client feasibility analysis identified **four blockers** to
allowing a TS developer to author Reventless aggregates, behaviours, and
projections natively in TypeScript:

1. **sury-ppx is ReScript-only** — TS callers cannot derive schemas from
   types at compile time; they would have to hand-write sury runtime calls
   or build a zod/valibot bridge.
2. Module functors → TypeScript generics (mechanical mapping).
3. DCB tag annotations need a TS-side equivalent.
4. No type declarations from compiled ReScript modules.

Sury alpha.5 (and alpha.4) implements **Standard Schema v1**, the cross-
library interface that zod, valibot, ArkType, and 19+ other schema
libraries implement. That changes Blocker 1's resolution from "write a
custom zod-to-sury bridge" to "consume the `~standard` interface that all
participating libraries already expose". The bridge collapses from a
significant one-time investment into a thin adapter.

This is the smallest pragmatic step toward TypeScript-authored Reventless
applications: an SDK package that lets TS code use the framework's runtime
primitives (Message envelope encode/decode, DCB tag extraction, command
dispatch) with schemas declared in the TS library of choice.

## Goal

Ship `@reventlessdev/reventless-client-ts` — a TypeScript SDK that:
- Accepts any Standard Schema v1 schema (zod, valibot, sury, …) for
  encoding commands and decoding events.
- Exposes a thin `dcbTag()` helper for marking tag fields without coupling
  to a specific schema library.
- Provides command dispatch and event subscription against the existing
  Reventless transport (HTTP for dispatch, see
  `docs/plans/Backlog/reventless-client-transport.md`).

Explicitly **not** in scope for v1:
- TS-authored aggregate behaviours, projections, or extension points
  running server-side. The SDK is **client-side only**: dispatch commands,
  subscribe to events, decode envelopes.
- Replacing sury inside the framework. Server-side stays on sury via the
  PPX; the SDK lets TS clients participate without sharing the PPX.

## What's already in place

- Sury implements Standard Schema v1 — both alpha.4 and alpha.5.
- `Message.commandJson` shape is documented in
  `docs/analysis/event-format-and-meta-review.md` — the SDK uses the same
  envelope.
- `docs/plans/Backlog/reventless-client-transport.md` covers the HTTP
  dispatch endpoint the SDK calls.

## Out of scope

- Server-side TS components.
- zod-to-sury schema conversion (the SDK works against the Standard Schema
  interface only — no specific library required, no bridge needed).
- WebSocket subscription transport (separate plan).

## Phases

### Phase 1 — `@reventlessdev/reventless-client-ts` package skeleton

Files in a new package directory `packages/reventless-client-ts/`:
- `package.json` (TypeScript, ESM, declares `peerDependencies` on
  `@standard-schema/spec` — no specific sury/zod/valibot dep).
- `src/index.ts` — public exports.
- `src/message.ts` — Message envelope shape (ported from ReScript record
  to a TS interface) + `encodeCommand` / `decodeEvent` helpers that take
  a Standard Schema and a value.
- `src/dcbTag.ts` — `dcbTag<T>()` brand wrapper for marking fields as DCB
  tags. TS-only; resolves to a TS phantom type and runtime no-op (the
  framework reads tag info from the Standard Schema's `~standard` metadata
  in Phase 2).
- `tests/` — vitest unit tests.

The `encodeCommand` / `decodeEvent` functions look like:
```typescript
import type { StandardSchemaV1 } from "@standard-schema/spec";

export type CommandJson = {
  id: string;
  meta: { service: string; time: string; msgId: string; correlationId: string; user?: string; ... };
  commandJson: { TAG: string; [k: string]: unknown };
};

export async function encodeCommand<T extends { TAG: string }>(
  command: T,
  schema: StandardSchemaV1<T, unknown>,
  meta: Partial<CommandJson["meta"]>,
): Promise<CommandJson> {
  const result = await schema["~standard"].validate(command);
  if ("issues" in result) throw new Error(formatIssues(result.issues));
  return {
    id: meta.id ?? deriveId(command),
    meta: completeMetaDefaults(meta),
    commandJson: { TAG: command.TAG, ...result.value },
  };
}
```

### Phase 2 — DCB tag extraction from Standard Schema metadata

**Goal:** the SDK extracts DCB tag values from a command/event by reading
schema-level annotations rather than the field name, so TS users mark tag
fields explicitly.

Standard Schema v1 has no first-class metadata field. Two options:

- **(A) Brand at the type level + per-field name registration on schema build.**
  ```typescript
  import { dcbTag } from "@reventlessdev/reventless-client-ts";

  const productAddedSchema = z.object({
    productId: dcbTag(z.string()),    // wraps the zod schema
    name: z.string(),
  });
  ```
  The `dcbTag` helper returns the inner schema unchanged at runtime but
  marks the field name in a side-channel `WeakMap` keyed by the schema
  object. The SDK reads this map when serialising to extract tag values.

- **(B) Convention-based**: any field name ending in `Id` is a tag. Matches
  the framework's auto-tagging convention but is fragile (typescript-client-
  feasibility analysis Blocker 3 calls this out).

Pick (A) — explicit. The framework's `@s.matches(DcbTag.string)` is
explicit on the ReScript side; the SDK should preserve that semantic.

### Phase 3 — HTTP command dispatch

**Goal:** the SDK posts encoded commands to the framework's HTTP dispatch
endpoint (from `Backlog/reventless-client-transport.md`).

Steps:
1. `Client.dispatch(command, schema, meta?)` calls `encodeCommand` then
   POSTs to the configured dispatch URL.
2. Authorization: pull a Cognito-issued JWT (or whatever auth the host
   chose) from a token provider injected at SDK init.
3. Response handling: framework returns the resulting events plus a
   correlationId; surface as a typed result with the events decoded against
   their schemas (also Standard Schema, passed by the caller).

### Phase 4 — Event subscription (deferred to subscription plan)

The SDK's subscription API is a thin wrapper around the framework's
GraphQL subscription transport once that lands
(`docs/plans/graphql-subscriptions-appsync.md`). Out of scope for this v1.

### Phase 5 — Type generation from spec packages (optional)

**Goal:** TS users get TypeScript types matching the ReScript-defined
aggregate commands without hand-writing them.

The hybrid approach `docs/analysis/rescript-client-architecture.md`
discusses: ReScript spec packages compile to `.res.mjs` with sury runtime
schemas. The SDK ships a build-time tool that:
1. Imports the `commandSchema` from a spec package's `.res.mjs`.
2. Walks the sury AST to derive TS interfaces.
3. Emits `.d.ts` next to the spec package.

The TS user `import { addProductCommand } from
"@reventlessdev/catalog-spec"`, gets the runtime sury schema (which
implements Standard Schema v1) plus matching TypeScript types — without
needing to write either by hand.

This step is optional; without it, TS users hand-write zod/valibot schemas
that mirror the ReScript types. With it, the experience matches the
ReScript developer's.

## Open questions

1. **Schema library choice for examples.** Which library to show in docs:
   zod (ubiquitous), valibot (smaller bundle), ArkType (TypeScript-native
   syntax)? Probably document all three with a "your library here" note —
   the SDK doesn't care.
2. **Phase 2 brand semantics across schema libraries.** The `WeakMap` keyed
   by the schema object needs the *inner* schema to be the same object
   passed to the validator. Verify with zod's `z.string().brand()`, valibot's
   `pipe(string(), brand())`, etc. — they may wrap and the WeakMap key
   could be the wrapper, not the original.
3. **DcbTag composite partition keys.** `@compositePartitionTag` on ReScript
   side joins fields in declaration order. The Standard Schema interface
   does not preserve declaration order in a portable way — TS users may
   need a separate `compositeKey([f1, f2])` helper.
4. **Phase 5 sury-AST-to-TS-types complexity.** Sury alpha.5's
   `S.toExpression` may help; if not, walk the schema runtime structure
   directly.

## Validation

- vitest unit tests for `encodeCommand` / `decodeEvent` round-trip against
  a sury schema, a zod schema, and a valibot schema.
- End-to-end: TS client dispatches `AddProduct` command via HTTP, the
  framework's Lambda decodes the same envelope, the resulting event is
  received and decoded back at the client. All against zod / valibot
  schemas on the TS side.
- Phase 5 (if undertaken): generated `.d.ts` matches a hand-written
  baseline for a representative spec package.

## Risks

| Risk                                                                       | Likelihood | Impact | Mitigation                                                                       |
| -------------------------------------------------------------------------- | ---------- | ------ | -------------------------------------------------------------------------------- |
| Standard Schema validate is sync-only across some libraries                | low        | medium | Spec says async-allowed via `Promise` return; SDK consumes the Promise either way |
| `dcbTag` WeakMap brand fragile under schema-library wrapping               | medium     | high   | Phase 2 step explicitly tests against zod + valibot + ArkType                    |
| Wire-format drift between SDK's TS interfaces and ReScript-emitted JSON    | medium     | high   | Round-trip end-to-end test on at least one of each component (cmd, event, query) |
| TS users expect server-side TS components — SDK does not deliver           | medium     | low    | Document clearly: v1 is client-side only; server-side is a separate, larger story |
| Phase 5 type generation drifts on sury alpha.6                             | medium     | medium | Pin the generator to a specific sury version; bump deliberately                  |

## References

- TS client blockers: `docs/analysis/typescript-client-feasibility.md`
- Standard Schema spec: <https://standardschema.dev/>
- Sury alpha.5 opportunities: `docs/analysis/sury-alpha5-migration.md` G
- HTTP transport (dependency for Phase 3):
  `docs/plans/Backlog/reventless-client-transport.md`
- Message envelope shape: `docs/analysis/event-format-and-meta-review.md`
- Hybrid client architecture: `docs/analysis/rescript-client-architecture.md`
