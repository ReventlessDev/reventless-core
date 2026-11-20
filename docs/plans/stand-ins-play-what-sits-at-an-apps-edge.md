# Plan: stand-ins play what sits at an app's edge, beside the local platform

**Date:** 2026-11-20<br/>
**Status:** 🔨 [SC1](#sc1-the-local-webhook-door-listens-over-http) to
[SC3](#sc3-a-schedule-can-be-fired-now) built 2026-11-20, with the doc page of
[SC8](#sc8-the-checks-and-the-docs)'s last point. Where the build differs from the steps:
- the doors are served at `/webhooks/<path>` on the domain server, so a path cannot shadow
  `/graphql` or `/sdl`; the running-platform entry names the base and the secrets file under
  `webhooks`;
- the secrets file, `.reventless/webhook-secrets.json`, also lists each door's path, header and
  secret name, so a caller needs nothing else; like the fingerprint key, it is only written where
  `.reventless/` exists, and an app the tools make ignores that folder but for its board status
  ([SCQ2](#open-questions), checked);
- the schedules are listed and fired at `GET /__inmemory/schedules` and
  `POST /__inmemory/schedules/fire`, and by the MCP tools `local_schedules` and
  `local_fire_schedule_now`.

[SC4](#sc4-the-stand-in-runtime) built 2026-11-20, not yet released: the package
[`reventless/standin`](../../reventless/standin/README.md). Where the build differs from the step:
- the test app is `reventless/standin/fixture`, a private workspace package (chargers, a signed
  meter-reading door, readings per session) that the runtime's suite starts as a child process;
  a published package cannot carry the PPX its slices need;
- a twin's instances are read again on a fixed interval (`refreshMs`); following the event tap
  ([SCQ1](#open-questions)) waits for [SC7](#sc7-the-local-platform-starts-the-stand-ins), where
  the stand-ins run beside the tap;
- the runtime reads views with the client it is given; the stand-ins' own account
  ([SCQ3](#open-questions)) comes with [SC7](#sc7-the-local-platform-starts-the-stand-ins).

Found while building it: on a fresh app the secrets file is missing on the first start, because
`.reventless/` is only made afterwards, by the registry entry, so [SC2](#sc2-the-local-platform-makes-each-doors-secret)'s
*done when* holds from the second start on. The runtime's suite makes the folder first.

The player plan, [done/seed-plays-forward-as-a-player.md](done/seed-plays-forward-as-a-player.md)
(*the player plan*), is done.<br/>
**Part of:** a wider plan that orders this work with the editor's tools, which generate an app's
stand-ins and show them; this plan holds core's part.<br/>
**Builds on:** the webhook door of an inbound translation
([`InboundTranslationSlice_Webhook.res`](../../reventless/core/src/components/InboundTranslationSlice/InboundTranslationSlice_Webhook.res)),
the seed client ([`reventless/seed`](../../reventless/seed/README.md)), the local schedules
([`LocalAutomationSchedules.res`](../../reventless/local/src/components/LocalAutomationSchedules.res))
and the running-platform registry
([`LocalPlatformRegistry.res`](../../reventless/local/src/LocalPlatformRegistry.res)).<br/>
**Facts from:** this repo at `1e69fca85`, surveyed 2026-11-20.

## In plain words

An app talks to things and services at its edge: a charger that sends its meter readings, a grid
operator that calls for less power, a payment provider that confirms. In development none of them
is there, so nothing arrives by itself and nothing arrives the way it will in production.

A **stand-in** plays one of them. It is a small program, outside the platform, that sends what the
real thing sends **through the door the real thing will use**, and answers what the app tells the
real thing. A stand-in for a *thing* has one **instance** per identity the app knows (Bay 1, Bay 2,
Bay 3), each with its own state (idle, charging at 22 kW, faulted, silent); a stand-in for a
*service* has one.

Three things are missing in core for that:
- the local platform's webhook door only takes posts from inside its own process, and it needs a
  secret that someone exported by hand;
- an outbound translation has no way to tell one thing something: it calls the outside world
  itself;
- nothing runs a stand-in, starts it with the platform, or lets a schedule run before it is due.

The steps are **SC1 to SC8**. **SC** stands for *stand-ins, core*. **SCD** are the decisions,
**SCQ** the open questions.

| Step | What | Waits on | Size |
|---|---|---|---|
| SC1 | The local webhook door listens over HTTP, at the path AWS serves it on | nothing | S |
| SC2 | The local platform makes each door's secret and says where it keeps them | nothing | S |
| SC3 | A schedule can be fired now, at the true time, over HTTP and MCP | nothing | S |
| SC4 | The stand-in runtime: kinds, instances, state, timers, sends through the door | [SP1](done/seed-plays-forward-as-a-player.md#sp1-a-pace-held-by-the-client), [SP5](done/seed-plays-forward-as-a-player.md#sp5-a-generated-adapter-read-from-the-command-definitions) | M–L |
| SC5 | A *devices* capability: tell one thing something, the stand-ins as its local provider | [SC4](#sc4-the-stand-in-runtime) | M |
| SC6 | Behaving as things do: silence, repeats, late readings, a clock that drifts | [SC4](#sc4-the-stand-in-runtime) | S–M |
| SC7 | The local platform starts the stand-ins and serves their state and their sends | [SC4](#sc4-the-stand-in-runtime) to [SC6](#sc6-behaving-as-things-do) | M |
| SC8 | The checks and the docs | all | S |

## Steps

### SC1 The local webhook door listens over HTTP

Today [`LocalWebhookRegistry.res`](../../reventless/local/src/adapter/Webhook/LocalWebhookRegistry.res)
has no HTTP server: a test calls `post(~path, ~headers, body)` in the same process. A stand-in, or
a tool, runs in another process and cannot reach it.

The local domain GraphQL server
([`DomainGraphQL_Server.res`](../../reventless/local/src/adapter/DomainGraphQL_Server.res)) gains
one more route that hands the raw body and headers to the registry's `post`, at the path
`InboundTranslationSlice_Webhook.routeOf` gives, so a caller builds the same path locally and on
AWS. The verification, the dispatch and the answers stay the registry's; the route only carries
the bytes. The body is read raw, never parsed first, since the signature is over the raw bytes.

**Done when:** an HTTP post of a signed body to the local platform reaches the inbound translation
and is answered as the Function URL on AWS answers it (accepted, refused, bad signature).

### SC2 The local platform makes each door's secret

A signed door reads its secret from `REVENTLESS_WEBHOOK_SECRET_<NAME>`; locally nobody sets it,
so every request gets a 500. At start the local platform:
- for each signed endpoint whose variable is not set, makes a random secret, keeps it in a file
  under the app's `.reventless/` folder, and uses it; the same secret on every start, so a
  stand-in started earlier still signs right;
- leaves a variable that is set alone, so a developer can still pin one;
- writes the file's path into its entry of the running-platform registry, beside `endpoint` and
  `loginEndpoint`, with each door's path.

The file is the local platform's and holds no real secret; it must never be committed
([SCQ2](#open-questions)).

**Done when:** a fresh app's local platform answers a post signed with the secret from the file,
and a stand-in finds both the door and the secret from the registry alone.

### SC3 A schedule can be fired now

A month's settlement waits for the month's end. `LocalAutomationSchedules.fire(~slice, ~key, at)`
exists but nothing outside the process reaches it.

The local platform serves:
- the list of schedules: slice, key, when each is next due;
- *fire now*: the tick for one slice and key, **at the current time**, as if it were due.

Both as an HTTP route beside the `/__inmemory/` ones and as tools of the local MCP server. Nothing
is backdated: the automation sees the true time and runs exactly the code the due tick will run,
as the player plan's rule on time demands
([its §4](done/seed-plays-forward-as-a-player.md#4-forward-only)). A fired tick does not move the next
due one.

**Done when:** firing a monthly schedule now on a local platform runs its automation once, with
today's date, and the schedule is still due at the month's end.

### SC4 The stand-in runtime

A new package beside `reventless/seed`, a client of the platform's public doors only:

- **A kind** is made once, for a thing (`Standin.Thing.make`) or a service
  (`Standin.Service.make`), with its state, its timers, the messages it may send and what it does
  when told something ([SC5](#sc5-a-devices-capability)).
- **Instances** of a thing come from the app's view that lists them, read through the GraphQL API
  as the seed reads; the runtime keeps no list of its own. An instance that appears in the view
  gets a twin, one that leaves it loses its twin ([SCQ1](#open-questions)).
- **A send** is the decision's payload as a JSON body, checked against the API's own description
  by the adapter the player plan generates
  ([SP5](done/seed-plays-forward-as-a-player.md#sp5-a-generated-adapter-read-from-the-command-definitions),
  `Seed.Commands.checkBody`: every inbound translation has a mutation whose arguments are its
  external input's fields), posted to the inbound translation's door and signed with its secret ([SC1](#sc1-the-local-webhook-door-listens-over-http),
  [SC2](#sc2-the-local-platform-makes-each-doors-secret)). Never a GraphQL mutation: that is the
  door people use, not the door a thing uses.
- **Timers** run forward only. Faster runs shorten the intervals by a speed beside the player's pace
  ([SP1](done/seed-plays-forward-as-a-player.md#sp1-a-pace-held-by-the-client), `Seed.Pace.parseSpeed`
  and `realMs`; a pace spaces sends, a speed shortens time); a value that grows with
  time (energy from power) is computed from the simulated interval, while every time sent is the
  true one.
- **Random values** come from the seed's seeded random, so a run is the same each time it is
  started with the same seed.
- **By hand:** any message of a kind can be sent for one instance on request, with fields given
  or filled from the instance's state ([SC7](#sc7-the-local-platform-starts-the-stand-ins)).
- **A stop** ends every timer and leaves no send half done, as the player's stop does
  ([SP4](done/seed-plays-forward-as-a-player.md#sp4-a-stop-that-waits-for-the-end-of-a-repetition)).

**Done when:** a test app's charger kind meters each running session every simulated minute
through the door, two runs with one seed send the same values, and a charger added to the view
starts metering without a restart.

### SC5 A devices capability

An outbound translation that tells a thing something (charge at 11 kW) has nowhere to send it:
`translate` calls the outside world itself and the framework knows no address per thing.

A capability beside `geocode` and `messaging` in
[`Capabilities.res`](../../reventless/spec/src/semantic/Capabilities.res): *tell this instance of
this kind this message*, answered with accepted, refused with a reason, or not reachable. The
translation names the kind and the instance; which provider carries it is the platform's
business, never the domain's.

This plan builds two providers:
- **locally**, the running stand-ins: the message reaches the twin of that instance, which answers
  from its state; with no stand-in running, the answer is *not reachable*, as a real charger that
  is offline;
- **in scenarios**, the fake of
  [`Capabilities_Fake.res`](../../reventless/gwt/src/Capabilities_Fake.res), which records the call
  and answers what the scenario says.

Providers for a deployed platform (a stand-ins' stack, a device broker, a charging system, a
thing's own connection) come with later plans; a deployed platform without one answers *not
reachable* ([SCD4](#decisions)).

**Done when:** a translation that tells Bay 1 to charge at 11 kW changes the power its twin meters
at, and a scenario of the translation reads the call from the fake.

### SC6 Behaving as things do

A stand-in kinder than the thing makes every run green. Per kind, switches with a rate:
- **silence**: an instance stops sending for a while and comes back, some with the readings it
  kept;
- **repeats**: a message is sent twice;
- **late**: a reading arrives after the session it belongs to ended;
- **drift**: a thing's own time is off by seconds.

Each is on by default at a low rate, so a plain run stays calm and a test run can turn it up. A
silence chosen on purpose is marked as such in the state [SC7](#sc7-the-local-platform-starts-the-stand-ins)
serves.

**Done when:** with repeats turned up, the test app's charger sends each reading twice now and
then, and its scenarios count the energy once.

### SC7 The local platform starts the stand-ins

An app's generated stand-ins package (one kind per thing or service the app has) is handed to the
local platform, as plugins are. After `Platform.startServers()`:
- the platform starts the stand-ins, unless `REVENTLESS_STANDINS=off`;
- a kind with a behaviour runs by itself; a kind without one is *by hand only*;
- the platform serves, as HTTP routes and as MCP tools: the kinds and their instances with their
  state, *send this message for this instance*, *switch this kind on or off*, and the
  misbehaviour switches of [SC6](#sc6-behaving-as-things-do);
- its entry in the running-platform registry says where those routes are.

The stand-ins stay a client of the platform: they run in the same process for convenience, but
send only through the doors of [SC1](#sc1-the-local-webhook-door-listens-over-http) and the
GraphQL API ([SCD1](#decisions)).

**Done when:** a test app's local platform starts with its chargers metering, a by-hand fault for
one charger sent over HTTP is refused or accepted as the app decides, and the platform starts
quiet with `REVENTLESS_STANDINS=off`.

### SC8 The checks and the docs

- Tests per step, at the level each step names in its *done when*.
- A component doc page for stand-ins beside the inbound translation's, saying what a stand-in is,
  how it is started, and that it never runs on a deployed platform yet.
- The inbound translation's doc page says the local door listens over HTTP and where its secret
  comes from.

## Order

[SC1](#sc1-the-local-webhook-door-listens-over-http) to [SC3](#sc3-a-schedule-can-be-fired-now)
are small, independent, and released together: the editor's tools can then send through the real
door and fire a schedule before any stand-in runs. They touch only the local platform's adapter,
its schedules and its registry, none of the files of the player plan, but are started after it,
since one working tree is shared.

[SC4](#sc4-the-stand-in-runtime) waits on the player plan's
[SP1](done/seed-plays-forward-as-a-player.md#sp1-a-pace-held-by-the-client) and
[SP5](done/seed-plays-forward-as-a-player.md#sp5-a-generated-adapter-read-from-the-command-definitions)
being released, so that it reuses the pace and the adapter instead of copying their shapes.
[SC5](#sc5-a-devices-capability) to [SC7](#sc7-the-local-platform-starts-the-stand-ins) follow and
are released together.

## Decisions

| # | Decision | Why |
|---|---|---|
| **SCD1** | A stand-in is a client of the platform's public doors: the webhook door to send, the GraphQL API to read, the devices capability to be told | A shortcut into the decision tests a path no thing takes, and passes while the translation is broken |
| **SCD2** | A stand-in is told things only through an outbound translation and the devices capability, never by watching the app's events | Watching events would let a simulation work while the real thing is never told; a missing translation must show |
| **SCD3** | Time runs forward only; *faster* is shorter intervals, a schedule is fired now at the true time | The player plan's rule ([its §4](done/seed-plays-forward-as-a-player.md#4-forward-only)) holds for every client |
| **SCD4** | This plan runs stand-ins on a local platform only; a deployed platform answers *not reachable* until a later plan gives it a provider | A deployed stand-in needs a kind of deployment that refuses it in production, a stack of its own, a rate and an end; none of that is here |
| **SCD5** | The runtime lives in core, beside the seed | A deployed demo must run it without the editor; it reuses the seed's client, random values and the player's pace |

## Open questions

Numbered **SCQ1 to SCQ3**, each with a recommendation.

**SCQ1. How does the runtime learn that an instance was added or removed?** It can read the view
again every minute, or follow the local event tap. **Recommendation: read the view at start and
again on each event the tap shows for the thing's identity**, with the minute's read as the
fallback when no tap is there (a deployed platform later). Revisit if reading on each event is too
often for an app with hundreds of things.

**SCQ2. Where does the local secrets file live?** **Recommendation: in the app's `.reventless/`
folder, beside the running-platform registry**, and the app's template ignores the folder, which
the step checks rather than assumes. Revisit if an app's `.reventless/` must be committed for
another reason; then the secrets get a folder of their own.

**SCQ3. Which account does a stand-in read the views with?** **Recommendation: an account of the
stand-ins' own, which the local platform adds as it adds the seed's accounts, with a role that may
read the views of things and services and send nothing through GraphQL.** Revisit when a deployed
platform needs it; there the role is the one a deployment of the right kind holds.

## Out of scope

- Stand-ins on a deployed platform: a kind of deployment that refuses them in production (the
  `purpose` of [`Environments.res`](../../reventless/spec/src/types/Environments.res) is a start),
  a stack of their own, a rate and an end time, the list of instances they play.
- A WebSocket door for protocols where the thing opens the connection, and an OCPP charge point
  stand-in.
- An MCP surface beyond what [SC3](#sc3-a-schedule-can-be-fired-now) and
  [SC7](#sc7-the-local-platform-starts-the-stand-ins) serve.
- Providers of the devices capability other than the stand-ins and the fake.
- Playing the people of an app: that is the seed player.
