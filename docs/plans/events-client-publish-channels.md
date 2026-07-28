# Plan: Client-publishable Events channels (`/client/**`) + local Events transport

**Date:** 2026-07-28
**Status:** IMPLEMENTED (2026-07-28) — Phases 1–5 landed (AWS namespace +
config advertisement + LocalBus hook + local transport + tests, plus a live
ws-handshake smoke run); Phase 6 (AWS E2E) is deploy-only and stays staged,
like the event-history AWS resolver.

## Motivation

The AppSync Events API is one-directional today: Lambda publishers push
read-model change descriptors to `/default/**`, and browser clients only
subscribe. `defaultPublishAuthModes: [AWS_IAM]`
([AppSync_EventsApi.res:126](../../reventless/aws/src/adapter/Api/AppSync_EventsApi.res))
is deliberate — a browser must never be able to forge a change descriptor —
but it also blocks a whole class of collaborative, ephemeral UI features that
need *client→client* fan-out through the platform: who-is-here presence,
typing indicators, transient chat. These messages are not domain events (they
must not land in an event log), so the command path is the wrong transport;
they are pub/sub payloads with at-most-once, connected-subscribers-only
semantics — exactly what the Events API already provides.

Separately, local dev has **no Events transport at all**: the dev server
exposes only `graphql-ws` for a handful of admin subscriptions, so the change
descriptors that Sources A/B publish on AWS never reach a locally-served
browser (`Platform.res` local: "Source B no longer flows through GraphQL —
clients consume Events channels directly"; the in-memory equivalent was left
unwired). Any client-publish capability would be untestable locally without
closing that gap first, and closing it also makes ordinary live list updates
work in local dev for the first time.

## Scope

| In | Out |
|---|---|
| A second channel namespace `client` on the Events API with Cognito publish + subscribe auth | Any change to `/default/**` (stays IAM-publish-only) |
| Capability advertisement in the emitted host-ui `config.json` (`clientEventsNamespace`) | Message schemas/conventions for presence or chat (consumer-defined; payloads are opaque to the platform) |
| Local Events transport on the domain dev server: realtime WebSocket (subscribe side, AppSync Events wire protocol) + HTTP publish route (client namespace only) | A local transport for the *platform* API's channels (`Platform_*` read models stay non-live locally) |
| LocalBus → local Events bridge for `/default` change descriptors (local live parity) | Persistence or replay of client-published messages (fire-and-forget, like all Events channels) |
| Local auth enforcement via LocalAuth tokens | Server-side identity stamping / per-publish validation (`onPublish` handler — staged, see Risks) |
| AWS: verified at deploy only (staged, like other deploy-only surfaces) | Rate limiting beyond what AppSync enforces natively |

## Design decisions

1. **A namespace, not an auth-mode change.** `defaultPublishAuthModes` stays
   `[AWS_IAM]`. A new `client` namespace sets per-namespace
   `publishAuthModes: [AMAZON_COGNITO_USER_POOLS]` (+ IAM, so server-side
   code may also publish there) and
   `subscribeAuthModes: [AMAZON_COGNITO_USER_POOLS, AWS_IAM]`. The
   per-namespace override fields already exist in the Pulumi binding
   ([AwsNative_AppSync_ChannelNamespace.res:66-68](../../rescript/pulumi-aws/src/AwsNative/AppSync/AwsNative_AppSync_ChannelNamespace.res))
   and were simply never used. Channels under `/client/**` are free-form;
   the platform relays them opaquely.

2. **Client publish is HTTP POST, not a WebSocket frame.** AppSync Events
   accepts `POST {endpoint}` with the JWT in the `Authorization` header and
   body `{"channel": "...", "events": ["<json string>", ...]}` — the same
   endpoint the config already hands to clients for realtime-URL derivation,
   with no SigV4 involved. Keeping the subscribe socket read-only means the
   existing wire protocol implementation needs no new frame types, and a
   publish works even while the socket is reconnecting. (If a WebSocket
   `publish` frame is ever wanted for latency, it is additive.)

3. **The local transport speaks the AppSync Events wire protocol.** Clients
   already implement connection_init/ack, subscribe with a `header-<b64url>`
   auth subprotocol, and stringified-JSON `data` frames (documented in
   [appsync-events-live-updates.md](../../packages/doc/docs-infrastructure/appsync-events-live-updates.md)).
   A local emulator that speaks the same frames means one client code path for
   dev and prod — no local-only transport branch. Endpoint contract:
   - `POST /events` on the domain dev server = the publish endpoint
     (analogue of AWS `POST {endpoint}`), client namespace only.
   - `ws://…/events/realtime` = the realtime socket (clients derive it from
     the configured endpoint by appending `/realtime`, mirroring the AWS
     host rewrite).

4. **Local `/default/**` parity comes from a LocalBus bridge, not client
   publishes.** `QueryDbStorage_*` already calls
   `Bus.publishStateChange(~name, ~descriptor)` with the AWS-shaped
   descriptor. A new all-changes hook fans those into the local Events
   transport on `/default/{name}/{id}` (segments normalized with the same
   `[^A-Za-z0-9-] → -` rule as `AppSyncEventsSigner_Ops.pathSegment`).
   Client HTTP publishes to `/default/**` are rejected 403 — the same
   asymmetry the AWS namespaces enforce.

5. **Local auth mirrors the HTTP dispatch rules.** Connection: an
   `Authorization` value inside the `header-` subprotocol that fails
   `LocalAuth.Login.verifyAndDecode` closes the socket (4401); absent means
   anonymous, matching `buildAuthContext`'s default-user fallback. Publish
   route: same verify on the `Authorization` header (raw or `Bearer `-prefixed),
   invalid → 401, absent → anonymous-allowed.

## Phases

### Phase 1 — AWS `client` namespace

`AppSync_EventsApi.res`:
- `let clientNamespaceName = "client"` (single source for the config emission).
- In `make`, create `ChannelNamespace.make(~name=name ++ "ClientNS", …)` with
  `name: "client"`, `publishAuthModes: [cognitoMode, iamMode]`,
  `subscribeAuthModes: [cognitoMode, iamMode]`.
- `type t` gains `clientNamespace?: ChannelNamespace.t` (optional field —
  the plugin-stack phantom in `Platform.res` constructs `t` without it).
- Module docstring: channel layout table gains the `/client/**` row and the
  publish-auth asymmetry rationale.

### Phase 2 — Capability advertisement

`Platform.res` (aws): the host-ui `config.json` emission adds
`("clientEventsNamespace", "client")` inside the events-endpoint branch —
present exactly when the events endpoints are. Clients treat the key's
absence as "capability not available" (the same staged-capability gate other
deploy surfaces use), so a UI feature depending on client publish never
half-renders against an API that would reject it.

### Phase 3 — LocalBus all-changes hook

`LocalBus.res`: module type `T` and `Impl` gain
`subscribeToAllStateChanges: ((~name: string, ~descriptor: JSON.t) => unit) => unit`
— a module-instance listener array invoked from `publishStateChange`
alongside the per-name listeners, cleared in `reset`. (All of
`Make`/`MakeSilent`/`MakeBounded` include `Impl`, so one change point.)

### Phase 4 — Local Events transport

New `reventless/local/src/adapter/Api/LocalEvents_Server.res`:
- **Connection registry**: `{send: string => unit, subscriptions: dict<subId → channel>}`
  per socket. Frame handling (`connection_init` → `connection_ack`,
  `subscribe` → register + `subscribe_success`, `unsubscribe` → drop) is a
  pure function over that record so tests drive it without sockets.
- **Channel matching**: exact, or subscription suffix `/*` = prefix match
  (AppSync wildcard semantics).
- **`broadcast(~channel, ~event)`**: one `data` frame
  (`{"type":"data","id":<subId>,"event":"<stringified>"}`) per matching
  subscription.
- **`broadcastStateChange(~name, ~descriptor)`**: builds the
  `/default/…` channel, stringifies the descriptor, broadcasts. No-op when
  no transport is attached (so Bus wiring is order-independent).
- **`handlePublish(~authorization, ~body)`** → `(status, JSON)`: token
  verify, JSON body parse, `channel` must start with `/client/`, `events`
  must be an array of strings that parse as JSON; fan out, reply
  `{"successful": [...], "failed": [...]}` in the AWS response shape.
  Transport-free signature so the HTTP layer stays in the dispatch module.
- **`attach(~server)`**: `ws` WebSocketServer at `/events/realtime`,
  `handleProtocols` pinned to `aws-appsync-event-ws`, auth from the
  `header-` subprotocol per decision 5.

`DomainGraphQL_Server.res`:
- `_dispatch` routes `POST /events` (body → `handlePublish` → JSON reply)
  and `OPTIONS /events` (CORS preflight, same headers as the served-object
  routes).
- `start()` calls `LocalEvents_Server.attach(~server)` after listen — all
  three start sites (split, unified, replay) get the transport.

`Platform.res` (local): after the Bus functor is instantiated,
`Bus.subscribeToAllStateChanges(LocalEvents_Server.broadcastStateChange)`.

### Phase 5 — Tests

`reventless/local/tests/adapter/LocalEvents_ServerTest.res`, socket-free via
the pure frame/connection API:
- wildcard matching (exact, `/*` prefix, non-match, `/default/x/*` vs
  `/default/xy/…`);
- subscribe → `broadcastStateChange` → data frame with the stringified
  descriptor on the right subscription id; unsubscribe stops delivery;
- `handlePublish`: 403 on `/default/**`, 401 on bad token, 400 on
  non-string events, fan-out to a `/client/**` subscriber, success/failed
  accounting;
- connection_init → connection_ack ordering.

### Phase 6 — AWS E2E (deploy-only, staged)

`pulumi up`, then from a browser session: subscribe to a `/client/…`
channel, `POST` the endpoint with a Cognito JWT, observe the data frame on a
second session; verify a `POST` to `/default/…` with the same JWT is
rejected. Joins the existing deploy-only checklist (map picker, presigned
upload, `/ui-hints.json`).

## Risks / open points

- **The AWS publish path is unverified inference — the plan's biggest open
  assumption.** Everything rests on per-namespace `publishAuthModes`
  overriding the API-level `defaultPublishAuthModes`, which is what lets a
  browser publish on `/client/**` while `/default/**` stays IAM-only. That
  reading comes from the Pulumi binding's field surface and the AWS docs, not
  from observation: the namespace has never been deployed. The local
  transport cannot corroborate it either — both ends of that emulator are
  written here, so it proves the protocol implementation is self-consistent,
  not that AppSync accepts a Cognito-authenticated publish. If the override
  does not behave as assumed, the fallback is a namespace `onPublish` CODE
  handler or a separate Events API for client channels. Phase 6 is what
  settles it; until then treat the AWS half as staged.
- **Payloads are client-asserted.** Anything on `/client/**` — including any
  claimed user identity inside a message — is untrusted client input; a
  malicious authenticated user can publish arbitrary JSON on any client
  channel. Consumers must render such content as data (never as markup) and
  must not gate anything security-relevant on it. Server-side identity
  stamping / validation is the natural job of a namespace `onPublish` CODE
  handler (the binding exists and is unused); staged until a consumer needs
  presence to be more than cosmetic, following the `registerSubscribeAuth`
  extension-hook shape.
- **No per-channel authorization within the namespace.** Any authenticated
  user can subscribe to and publish on any `/client/**` channel. Acceptable
  for presence/typing/transient chat among colleagues in one tenant; a
  multi-tenant deployment wants the extension hooks (`onSubscribe` already
  exists, `onPublish` per above) before exposing anything sensitive.
- **Local transport is domain-server only.** `Platform_*` read models keep
  no local live path; the platform admin UI already has its own `graphql-ws`
  channels for what it needs locally.
- **Publish quota/size limits differ.** AWS enforces its own event size and
  rate quotas; the local route enforces only JSON validity. A payload that
  works locally can be rejected at the AWS quota — consumers should keep
  client messages small (presence heartbeats are ~100 bytes).
- **In-memory `changeKind` degradation carries over.** The local bridge
  relays what `publishStateChange` emits: save() is always `Updated` on the
  in-memory backend (no INSERT detection), so "Added"-specific client
  behavior is only observable on SQLite/AWS. Pre-existing, now merely
  visible.
