# Plan: promote the reusable GraphQL server runtime into core

**Status**: Done (2026-07-11) — executed as **Option B** (new shared package).

## Outcome (Option B)

Landed as a new package `@reventlessdev/reventless-graphql-server`
(`reventless/reventless-graphql-server/`, namespace `ReventlessGraphqlServer`),
depending on `reventless-core` (Logger, Stitcher) + `rescript-graphql-yoga`.
`graphql-yoga` stays out of `reventless-core`'s manifest.

What landed:

- **Transport externals lifted** into `rescript-graphql-yoga/src/GraphqlYoga.res`
  (`wsServer`, `newWebSocketServer`, `wsUseServer`); `ws` + `graphql-ws` made
  explicit `dependencies` of the bindings package.
- **`GraphQL_ServerInstance.res`** moved into the new package verbatim, its
  `ws`/`graphql-ws` calls repointed at the bindings (`YG.newWebSocketServer` /
  `YG.wsUseServer`). No logic change.
- **`GraphQL_SubscriptionBridge.res`** (new) holds the generic bits — topic
  naming (`sourceATopic`/`sourceBTopic`), `makeFieldResolver`, `registerAll`,
  `publish`, `@aws_subscribe` stripping, `scalar AWSJSON` injection — all
  **parameterized over a `~pubSub` argument** (the one seam).
- **`reventless-local` repointed**: `LocalGraphQL_SubscriptionResolvers.res`
  keeps its exact public API but now owns only the in-process PubSub singleton
  and the `Bus`→PubSub glue (`bridgeSourceA/B`), delegating everything generic
  to the bridge with `~pubSub=getPubSub()`. The local
  `adapter/GraphQL_ServerInstance.res` copy was deleted; ~9 consumer files were
  requalified to `ReventlessGraphqlServer.GraphQL_ServerInstance`.

Verification (all green):

- `rescript-graphql-yoga`, `reventless-graphql-server`, and `reventless-local`
  all build with **zero warnings**.
- Full `reventless-local` suite: **491/491 pass** (74 suites), unchanged.
- New focused seam test
  (`tests/adapter/GraphQLSubscriptionBridgeTest.res`) drives the promoted
  modules with an **explicitly injected** in-process PubSub: `registerAll`
  builds subscription SDL + strips `@aws_subscribe` + injects `AWSJSON`;
  `makeFieldResolver`+`publish` deliver over the injected PubSub; two separate
  injected PubSubs stay isolated.
- Promoted files grep clean of `Local`/`Bus`/`InMemory`/`Domain`.

---

**Status**: Draft (2026-07-11)
**Nature**: pure code move + one small seam. A transport-neutral GraphQL server
factory (schema-from-fragments, resolver registration, an HTTP + `graphql-ws`
listener, and a subscription fan-out bridge) currently lives inside the
in-process `reventless-local` adapter. Every other platform backend that wants
to serve the same stitched schema has to fork it. This plan lifts the genuinely
generic pieces to a shared home so any backend builds a Yoga-backed API without a
private copy that drifts. **No behavioral change to `reventless-local`.**

## Motivation

Core already owns the **compile-time** half of the GraphQL story, and owns it
transport-agnostically by deliberate design:

- `src/components/Api/GraphQL_Stitcher.res` — fragment stitching + the
  catastrophic-shrink guard; its own comment states the output is "ready for use
  with AppSync or graphql-yoga."
- `src/components/Api/GraphQL_FragmentGenerator.res` — SDL fragments from
  ReScript schemas.
- `src/components/Api/GraphQL_SchemaInspector.res`, `Api_Builder.res`,
  `Api_Naming.res` — the rest of the neutral toolchain.
- `src/plugin/component/Plugin_SubscriptionSchema.res` — generates the
  subscription SDL field names.

The **runtime** companion to all of the above — the thing that takes stitched
SDL + a resolver map and actually stands up a server, attaches `graphql-ws`, and
fans out subscription events — is stranded one layer down in
`reventless-local/src/adapter/`. It has no local-specific logic in it (see the
inventory below), yet it can only be reached by depending on `reventless-local`,
which is a **peer runtime adapter**, not a shared library. So a second backend
faces a false choice: depend on a sibling adapter (wrong dependency direction),
or fork the file (drift).

This is the same push-upstream seam policy the repo already applies to runtime
hooks: when a genuinely framework-level capability is trapped in one backend,
promote it — framework-only wording, no backend assumptions — rather than
copying it. Promoting it also removes a standing obstacle to the recorded option
of splitting the hardened Yoga subscription runtime out as OSS: once the neutral
core is in a neutral home, the split is a packaging decision, not a disentangling
one.

## What moves and what stays

The `reventless-local` GraphQL adapter is already factored into a **generic
server instance** and a **local-specific singleton** built on top of it. That
existing split is exactly the promote/keep line.

### Promote (transport-neutral — no `reventless-local` concept inside)

| Unit | Current location | Only framework coupling |
|---|---|---|
| `GraphQL_ServerInstance` — `make(~label) => t`: independent server with an isolated registry (`registerMutations/Queries/Subscriptions/Types`, `buildSdl`, `getSchema`, `start(~port, ~contextFactory)`, `stop`, `reset`, `diagnostics`) | `src/adapter/GraphQL_ServerInstance.res` | `Logger` + `GraphQL_Stitcher.extractLeadingName` — both already core |
| The `ws` `WebSocketServer` + `graphql-ws/lib/use/ws::useServer` externals (currently declared **inline** in `GraphQL_ServerInstance.res`) | same file, lines ~17–22 | none (raw externals) |
| The generic subscription-bridge mechanism — topic naming (`on<Name>EventLog_eventAppended` / `on<Type>_stateChanged`), `makeFieldResolver(topic)`, `registerAll(~server, …)`, and the `@aws_subscribe`-directive stripping | `src/adapter/Api/LocalGraphQL_SubscriptionResolvers.res` | the topic names it must match are generated by core's `Plugin_SubscriptionSchema` |

The server instance's only two references outside the `ws`/yoga bindings are
`ReventlessCore.Logger` and `ReventlessCore.GraphQL_Stitcher` — both already in
core, so **nothing points back into `reventless-local`.** The move is clean in
one direction.

### Keep in `reventless-local` (in-process transport / domain-specific)

- `DomainGraphQL_Server.res` — the local singleton: custom Node HTTP router
  (`/sdl`, `/__inmemory/login|logout`), baked-in `LocalAuth`/`buildAuthContext`,
  Relay global-ID encode/decode + `node(id)` registry, `rebuildSchema`. All of
  this is in-process-dev behavior. After promotion it becomes a **consumer** of
  the promoted `GraphQL_ServerInstance` (it already mirrors that interface).
- `LocalGraphQL_Adapter.res` — the `Api_Adapter.Provider` implementation
  (`type api = unit`, no-op `makeApiResource`). Backend-specific by definition.
- `PlatformGraphQL_Server.res` — admin singleton + `wrapAdmin` group-gate.
- `CommandGeneratorResolvers_GraphQL.res`, `QueryDbResolvers_GraphQL.res`,
  `InboundTranslationResolvers_GraphQL.res` — resolver wiring coupled to
  commands / QueryDb / Effect. These stay; they show the registration contract
  but are not generic.
- The `Bus` wiring at the call sites (`Platform.res`) that connects the local
  in-process event bus to the subscription bridge.

## The one seam: a pluggable PubSub backend

The subscription bridge today constructs an **in-process** PubSub
(`GraphqlYoga.createPubSub()`) as a module singleton. In-process fan-out is
correct for a single-process server but cannot deliver an event published by one
server instance to a subscriber connected to another. Any backend that runs the
gateway as more than one process needs cross-process fan-out.

So the single behavioral seam introduced by this promotion: **the promoted
bridge takes its PubSub instance as a parameter** instead of constructing one.
The framework fixes the *interface* (publish a payload on a topic; subscribe
returns an async iterable) and the *topic vocabulary* (already fixed by
`Plugin_SubscriptionSchema`); it does **not** pick the backend. `reventless-local`
supplies the in-process `createPubSub()` it uses today — byte-identical behavior.
A backend needing cross-process delivery supplies its own implementation of the
same interface. No pub/sub product, transport, or topic-transport wording enters
core.

This mirrors the `contextFactory` parameter the server factory already exposes
for auth/context injection — the pattern is established; this adds one more
injection point of the same shape.

## Landing place — the decision to make

`GraphQL_ServerInstance` instantiates a concrete GraphQL server, so wherever it
lands, that module tree gains a dependency on the `rescript-graphql-yoga`
bindings. Today those bindings are **zero-dependency** and consumed **only by
`reventless-local`**. Three candidate homes:

**Option A — `reventless-core/src/components/Api/` (recommended).**
Put `GraphQL_ServerInstance` next to the SDL toolchain it completes (`Stitcher`,
`FragmentGenerator`, `SchemaInspector`, `Api_Builder`) and the subscription-topic
generator it must agree with (`Plugin_SubscriptionSchema`). Lift the `ws` /
`graphql-ws` externals into `rescript-graphql-yoga` (it stays a thin bindings
package — it just gains more externals, still zero first-party deps). Core gains
one new bs-dependency: `@reventlessdev/rescript-graphql-yoga`.
- *For:* the compile-time and runtime halves of the same capability live
  together; consumers already reach for `ReventlessCore.GraphQL_*`; one obvious
  import path; no new package to publish.
- *Against / tradeoff to accept explicitly:* core's npm closure gains
  `graphql` + `graphql-yoga`. The module is **additive and self-contained** —
  nothing in core's existing surface imports it, so a backend that serves no
  GraphQL never references it — but the dependency is nonetheless declared on the
  framework package. This is the main thing to sign off on.

**Option B — a new shared package (e.g. `reventless-graphql-server`)** depending
on both core (Logger, Stitcher) and the bindings.
- *For:* keeps `graphql-yoga` out of core's manifest; the server runtime is
  independently versioned and is the natural artifact to hand to a future
  OSS split.
- *Against:* a new package to publish, version, and wire into every consumer's
  overlay/link setup; heavier than a one-file move for what is, today, one
  consumer plus one in-development one.

**Option C — fold `GraphQL_ServerInstance` into `rescript-graphql-yoga` itself.**
- *Against:* inverts the layering — the thin bindings package would have to
  depend on core (`Logger`, `Stitcher`), turning a pure externals package into a
  stateful mini-framework. Rejected.

**Recommendation: Option A**, unless keeping `graphql-yoga` out of the core
manifest is a hard constraint — in which case Option B, and this plan's steps
change only in *where* the files land (the seam and migration are identical).
Settle this before moving code.

## Migration steps

1. **Lift the transport externals.** Move the `ws` `WebSocketServer` (`@new
   @module("ws")`) and `graphql-ws/lib/use/ws::useServer` externals from inside
   `GraphQL_ServerInstance.res` into `rescript-graphql-yoga/src/GraphqlYoga.res`,
   next to the existing `createYoga`/`createServer`/`createPubSub` externals.
   Add `ws` + `graphql-ws` to the bindings package's `dependencies` (they are
   already transitively present via `graphql-yoga`; make them explicit).
2. **Move the server factory** to the chosen home (Option A: `src/components/Api/
   GraphQL_ServerInstance.res`). Repoint its `ws`/`graphql-ws` calls at the
   bindings module. No logic change.
3. **Promote the generic subscription bridge.** Extract the transport-neutral
   functions (`makeFieldResolver`, `registerAll`, the topic-naming helpers, the
   `@aws_subscribe` stripping) into a core module (e.g. `GraphQL_SubscriptionBridge`
   in the same `Api/` dir). **Parameterize the PubSub** per the seam above.
   Leave the `Bus`-sourced `bridgeSourceA/B` glue at the local call site (it
   already takes its event source as a parameter; it now also passes the
   in-process PubSub in).
4. **Repoint `reventless-local`.** `DomainGraphQL_Server`,
   `PlatformGraphQL_Server`, and `LocalGraphQL_SubscriptionResolvers` consume the
   promoted modules from `ReventlessCore.*`. Delete the now-empty local copies.
   `reventless-local` still depends on `rescript-graphql-yoga` directly for any
   externals it uses outside the factory (e.g. `resolverFn`); that dep stays.
5. **Declare the new dependency** (Option A: add `@reventlessdev/rescript-graphql-yoga`
   to `reventless-core`'s `package.json` + `rescript.json` bs-dependencies).
6. **License headers.** The `.res` sources carry no per-file SPDX/Apache headers
   today, only descriptive comment headers; the packages are Apache-2.0 at the
   manifest level. If core policy wants per-file headers on promoted framework
   code, add them during the move (one-time, mechanical).

## Verification

The whole point is zero behavioral change to the existing consumer, so the gate
is the **existing `reventless-local` GraphQL surface, unchanged**:

- `reventless-local` builds in link **and** release mode after the move.
- Its GraphQL/subscription tests pass identically (same schema built, same
  resolvers registered, same `graphql-ws` fan-out). Add a focused test that the
  promoted `GraphQL_ServerInstance` builds SDL + serves a query/subscription
  driven by an **injected** in-process PubSub, proving the parameterized-PubSub
  seam is behavior-preserving.
- A diff review confirming no `reventless-local`-specific identifier survived the
  move into core (grep the promoted files for `Local`, `Bus`, `InMemory`,
  `Domain`).

## Non-goals

- **Not** building any specific backend's gateway, provider, auth, or
  cross-process PubSub implementation. This plan only relocates the neutral
  runtime and opens the PubSub seam; a concrete external-backed PubSub, a
  non-local `Api_Adapter.Provider`, and a real `makeApiResource` are downstream
  consumers' work, tracked in their own plans.
- **Not** changing `reventless-local`'s in-process router, auth, Relay
  global-ID, or admin behavior — those stay exactly where they are.
- **Not** stitching, fragment-generation, or shrink-guard changes — those are
  already in core and reused as-is.

## Consumers (context, not scope)

The immediate second consumer is the in-development Kubernetes runtime backend,
whose gateway needs (a) to build the same stitched Yoga schema without forking
this factory and (b) a cross-process PubSub for a multi-replica gateway — i.e.
exactly the promotion and the one seam above. Listing it only to show the seam is
real, not speculative; none of its specifics belong in core.
