# Harmonize the local deploy lifecycle with AWS

**Status:** SUPERSEDED 2026-07-14 by
[docs/plans/done/merged-api-push-free-composition.md](../done/merged-api-push-free-composition.md)
(Phase 6). The staged register→push→wait mechanics this proposal mirrors were
RETIRED with the push machinery — there is no fragment registration, no reactive
push, and no deploy waiter on AWS anymore. What remained of the goal ("one mental
model for how a platform/plugin comes up") is delivered by Phase 6: on both
platforms each plugin is an independent, standalone-validated subgraph and the
platform composes them (AWS: source APIs + AUTO_MERGE; local: per-plugin
subschema buckets merged at start, with per-plugin validation and
merge-conflict attribution). The residual idea below — running local plugin
deploys as separately-timed stages against an already-running server — has no
remaining production analogue to mirror (AWS plugin deploys don't stage against
the platform's schema anymore; they own their source API) and the local platform
is single-process, so it is retired rather than deferred.
**Origin:** Spun off from `docs/plans/event-sourced-fragment-registries.md` (Phase 2, scope 2)
during the schema-fragment-registry work (2026-07-12). Scope 1 (uniform reactive
registry-driven schema push on local) was done in Phase 2; this was the deferred scope 2.

## Problem

The local platform collapses platform + plugin deployment into a single in-process
construction: `makePlatform(~plugins=[…])` builds the platform infra AND every plugin at
once, then `connectPlugin` runs in-process. AWS, by contrast, deploys the platform as one
Pulumi stack and each plugin as a **separate, independently-timed** stack, with the plugin's
deploy registering its fragment (SigV4 `RegisterApiFragment`), waiting for schema-ACTIVE, then
creating its resolvers, and connecting at runtime via the handshake.

This structural difference means local tests do not exercise the same
deploy → register → push → wait → wire-resolvers → connect flow that production uses. Bugs in
ordering, the deploy waiter, cross-stack registration, or partial-schema windows can only
surface on real AWS.

## Proposal

Make the local platform mirror AWS's staged lifecycle:

1. **Platform deploy** — stand up platform infra + bootstrap the admin schema (seed admin base
   + registration mutations), independent of any plugin.
2. **Per-plugin deploy** — each plugin, as its own stage: register its fragment via
   `RegisterApiFragment` → the single writer rebuilds the schema → (in-process, synchronous)
   wait for the fields → wire the plugin's resolvers → connect (handshake).

The SDL/resolver seam stays as-is (registry drives SDL; resolvers are plugin-provided
functions locally) — scope 1 already established the reactive registry-driven SDL path, so this
is about staging the *lifecycle*, not the schema mechanism.

## Value

- Local (and Jest) exercise the exact production deploy flow — real test fidelity for ordering,
  the deploy waiter, and partial-schema windows.
- One mental model for "how a platform/plugin comes up" across providers.

## Cost / risk

A substantial reventless-local refactor touching `makePlatform`/`deployPlatform`/`connectPlugin`
and the schema-construction path that all local tests depend on. Deliberately kept out of the
fragment-registry work to avoid ballooning that change.

## Related

- `docs/plans/event-sourced-fragment-registries.md` (scope 1 done there)
- `docs/plans/Backlog/deploy-runtime-separation-plan.md`
