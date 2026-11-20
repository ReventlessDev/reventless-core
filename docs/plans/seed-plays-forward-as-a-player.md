# Plan: the seed becomes a player, and generates its own adapter

**Date:** 2026-09-20, revised 2026-11-20<br/>
**Status:** 🔨 Built 2026-11-20, not yet released: [SP1](#sp1-a-pace-held-by-the-client) to
[SP6](#sp6-commands-as-data-for-a-caller-without-rescript). Of [SP7](#sp7-the-checks), the adapter
equality is a test; the other three checks were run by hand against a local platform, not in CI
([§8](#8-what-was-built)). Where the build differs from the steps below:
- the adapter reads GraphQL introspection of the domain API, not the command definitions
  ([SPQ2](#7-open-questions) answered the other way);
- a set is marked `repeatable` and `SEED_REPEAT` chooses how often, rather than a `repeat` on the
  set; the follow-up run needed no repetition number, since it already numbers itself from the
  ids in the shop;
- the file player is `SEED_FILE`, read by every app's seed entry, not a bin of its own; its file
  is a flat list of steps with waits, not phases.<br/>
**Repos:** `reventless-core` only.<br/>
**Builds on:** [online-shop-seed-over-days.md](done/online-shop-seed-over-days.md), which gave the
seed a repeatable follow-up run and is the source of the constraint in
[§4](#4-forward-only).<br/>
**Facts from:** this repo at `1e69fca85`, surveyed 2026-11-20.

> **Questions and short answers**
>
> - *What does this plan add?* **Time and a generated adapter.** A run can send its commands at a
>   pace, repeat until asked to stop, and stop between two repetitions
>   ([SP1](#sp1-a-pace-held-by-the-client) to [SP4](#sp4-a-stop-that-waits-for-the-end-of-a-repetition)).
>   A caller with only a running endpoint gets its command-to-mutation mapping from the platform
>   instead of writing it ([SP5](#sp5-a-generated-adapter-read-from-the-command-definitions)).
> - *Does it change how the seed reaches the platform?* **No.** Every command still goes through
>   the public GraphQL API, the generated adapter included.
> - *Can a run be made to look as if it happened yesterday?* **No, and that is refused, not
>   deferred** ([§4](#4-forward-only)). A player compresses or stretches the gaps between real
>   events; it never writes a past time.
> - *Do existing data sets have to change?* **No.** The pace is held by the client every data set
>   already sends through, so the demo seed and the follow-up run play at a pace unedited
>   ([SPQ1](#7-open-questions)).

---

## 1. In plain words

A **seed** fills a platform with demo data by sending real commands through its public API: add
these categories, register these customers, place these orders. The package that does this,
[`reventless-seed`](../../reventless/seed/src), sends everything as fast as the platform answers
and then stops. A seeded shop therefore appears fully formed, all at once.

That is wrong for three uses. Watching a live view fill needs rows to arrive one by one. An
automation that reacts to arrivals needs arrivals spread over time. A demonstration that a system
is *running*, not merely *populated*, needs traffic that keeps coming. This plan turns the seed
into a **player**: the same commands, sent at a chosen pace, repeated until someone asks it to
stop.

The second gap is the **adapter**: the code that turns a plugin's typed commands into GraphQL
mutations. Today each app writes its own by hand (the online-shop example's is
[`DemoCommands.res`](../../examples/online-shop-hybrid/seed-data/src/DemoCommands.res), 287
lines). That is right for a ReScript app, which gets a compile error when a command changes. It is
a wall for anyone not writing ReScript, and everything it encodes is already published by the
platform itself. This plan generates it.

The steps are numbered SP1 to SP7 (**SP** for *seed player*); open questions are SPQ1 to SPQ4.

---

## 2. What the seed does today

- **It sends, it does not wait.**
  [`Seed_Client.sendAll`](../../reventless/seed/src/Seed_Client.res#L503) sends a list of mutations
  one after another; the only sleep in the client is the retry backoff of a transient error.
- **Phases are a data set's code, not a primitive.** The package has no phase type.
  [`HybridSeedData.res`](../../examples/online-shop-hybrid/seed-data/src/HybridSeedData.res) writes
  each phase as its own `sendAll` call, with domain checks between them
  (`waitForIds` before the orders that need products). A schedule can therefore not "compose with
  phases" as a value; it can only sit underneath them, in the client.
- **A run is a one-shot, or a follow-up.** The first run refuses a store that holds data
  (`probeViews`, [`Seed_Runner.assertStoreEmpty`](../../reventless/seed/src/Seed_Runner.res)). The
  follow-up run, `runFollowUp` with its `preflight`, adds a day of activity to a filled shop; its ids
  and its random generator are named by the run date and the run's number that day
  ([`DemoFollowUp.res`](../../examples/online-shop-hybrid/seed-data/src/DemoFollowUp.res)). It is
  already the repeatable unit a loop needs, except that its number comes from the date.
- **Every end is an exit.** [`Seed_Runner.run`](../../reventless/seed/src/Seed_Runner.res) exits the
  process on success and on failure, and reports any failure as "the store is now half-seeded".
  Nothing listens for a signal, so Ctrl-C stops a run mid-phase with no report at all.
- **The adapter is the caller's.** [`Seed.res:6`](../../reventless/seed/src/Seed.res#L6): *"the
  mapping from a plugin's command types to `mutation` values is the caller's adapter."*
- **What a generator would read is published.** Each command's definition on the component
  definitions API ([`Platform_ComponentDefinitionsApi.res`](../../reventless/core/src/admin/Platform_ComponentDefinitionsApi.res),
  type `Platform_CommandDef`) carries its `mutationField`, its JSON `schema`, its
  `aggregateIdField` and its `requiredAccess`. That is what a generated command form is built from.
  The SDL golden ([`domain-api.graphql`](../../examples/online-shop-hybrid/schema/domain-api.graphql))
  says the same per argument but loses the command's own name and which argument is the entity id.

---

## 3. Steps

| Step | What | Size |
|---|---|---|
| [SP1](#sp1-a-pace-held-by-the-client) | A pace held by the client, applied to every send | S |
| [SP2](#sp2-a-pace-chosen-per-run) | A pace chosen per run, without editing the data set | S |
| [SP3](#sp3-a-loop-repeats-a-follow-up-run) | A loop repeats a follow-up run, numbered by repetition | M |
| [SP4](#sp4-a-stop-that-waits-for-the-end-of-a-repetition) | A stop that waits for the end of a repetition | M |
| [SP5](#sp5-a-generated-adapter-read-from-the-command-definitions) | A generated adapter read from the command definitions | M |
| [SP6](#sp6-commands-as-data-for-a-caller-without-rescript) | Commands as data, for a caller without ReScript | S |
| [SP7](#sp7-the-checks) | The checks of [§5](#5-verify) | M |

### SP1 A pace held by the client

`Seed_Client.t` gains an optional **pace**: a function from the send's index to the wait before
it, in milliseconds. `send` waits on it before every mutation, so every data set paces without
change. No pace is today's behavior. Retries keep their own backoff and do not count as sends.

A pace is a value, not a loop of sleeps in a data set, which is what lets the same run play
faster or slower ([§5](#5-verify), first check). Two shapes cover the uses: a fixed gap, and a
mean rate with seeded jitter from [`Seed_Random`](../../reventless/seed/src/Seed_Random.res), so a
paced run repeats itself exactly.

### SP2 A pace chosen per run

`SEED_PACE` names it at the command line (`2s`, `30/min`, `30/min~` for jittered), read the way
`SEED_SET` and `SEED_ROLE` are. A data set may also set a default on its `dataSet` record, which the
variable overrides. A pace the parser cannot read refuses the run before anything is sent.

### SP3 A loop repeats a follow-up run

A `dataSet` gains an optional `repeat`: the run calls `seed` again until stopped, handing it the
repetition's number. That number takes the place the run's number on a date takes today: the
follow-up run names ids and seeds its generator by `(runDate, repetition)`, so repetitions never
collide and a given repetition repeats itself. A data set guarded by `probeViews` cannot repeat
(its second pass would find the store full); the runner refuses that combination at start.

### SP4 A stop that waits for the end of a repetition

The first SIGINT or SIGTERM asks the player to stop: the repetition in progress finishes, and the
runner reports how many repetitions ran and exits 0. A second signal stops at once, and the
report then says which repetition was cut short. Because the follow-up run decides everything
from a snapshot before it sends, a repetition is the only boundary at which the player's own story
(an order placed, then shipped) is whole.

What the platform does after the last command (an automation reacting, a projection catching up)
is the platform's and goes on without the player. The stop says so rather than waiting for it.

A failure inside a repeating run says "this repetition stopped part way", not "the store is now
half-seeded": the store was valid before it and still holds every earlier repetition.

### SP5 A generated adapter read from the command definitions

A new module, `Seed.Commands`, fetches the command definitions once per run and turns a command
named as its plugin and variant, with a JSON payload, into a `mutation`. It reads each definition's
`mutationField` for the field, its `aggregateIdField` for the separate `id` argument an aggregate
takes, and its JSON `schema` for how each value is rendered: an enum unquoted, a nested record as an
input object, money as `{amount, currency}` with the currency as an enum. Those are the details the
hand-written adapter centralizes today.

It goes through the same front door: it only produces `mutation` values, which `Seed_Client.send`
sends like any other. The hand-written adapter stays the path for a ReScript app, which keeps its
compile errors ([SPQ3](#7-open-questions)).

### SP6 Commands as data, for a caller without ReScript

A data set can be a file: a list of `{command, payload}` entries in phases, with `pace` and
`repeat` as in [SP2](#sp2-a-pace-chosen-per-run) and [SP3](#sp3-a-loop-repeats-a-follow-up-run).
A bin, `reventless-seed-play <file>`, connects as the seed does today, encodes each entry with
[SP5](#sp5-a-generated-adapter-read-from-the-command-definitions) and plays it. Ids in the file may
name the repetition (`ord-{rep}-1`) so a repeating file does not collide with itself.

### SP7 The checks

The checks of [§5](#5-verify), as tests in `reventless/seed/tests` against a local platform, with the
online-shop example as the specimen.

---

## 4. Forward only

[online-shop-seed-over-days.md](done/online-shop-seed-over-days.md) puts backdating out of scope on
a stated ground: *"It would turn the recorded time into a claim made by the caller, and automations
would still react at today's time, so a backdated order's trail would read out of order."*

**That refusal stands.** A player plays *forward*: it changes the gaps between events, never the
time an event records. "An hour of traffic" is a shape (arrival rate, ordering, concurrency), not a
set of timestamps. A request for real past timestamps asks for a different mechanism than a seed,
and is answered so rather than accommodated here.

**Anti-requirement: never write rows into a view to make it look busy.** A player exists to produce
real traffic; a view filled behind the domain's back hides precisely the defects a seeded run is
worth having. If the player cannot reach a state through commands, that is a finding about the
domain, not a reason to fake the state.

---

## 5. Verify

- A paced run takes the wall-clock time its pace implies, within a tolerance, and the same run
  without a pace ends in the same state, compared view by view.
- A repeating run stopped by one signal ends after a whole repetition: every order it placed in
  that repetition has the follow-ups the repetition planned for it.
- The generated adapter and [`DemoCommands.res`](../../examples/online-shop-hybrid/seed-data/src/DemoCommands.res)
  render the same mutation text for every command the demo seed sends.
- No event carries a time earlier than the send of the command that caused it, checked over every
  event a paced run produced, not assumed from [§4](#4-forward-only).

---

## 6. Out of scope

- **Backdating.** [§4](#4-forward-only). Refused, not deferred.
- **Starting a player on a schedule.** Starting a run is a separate concern, as the sibling plan
  says of its own follow-ups.
- **A UI for it.** The surface that offers this to someone not running a CLI belongs wherever that
  surface lives; this plan makes it possible and stops.
- **Concurrent senders.** One player sends one command at a time. Several players against one
  platform already work, each with its own repetition ids.

---

## 7. Open questions

- **SPQ1.** *Should the pace live in the client or in a new runner around the data set?*
  **Recommendation: the client** ([SP1](#sp1-a-pace-held-by-the-client)). Phases are a data set's
  own `sendAll` calls ([§2](#2-what-the-seed-does-today)), so a runner around them sees only the
  whole run; the client sees each send and paces every existing data set unedited.
- **SPQ2.** *Should the generator read the command definitions, live GraphQL introspection, or the
  committed SDL golden?* **Recommendation: the command definitions**
  ([SP5](#sp5-a-generated-adapter-read-from-the-command-definitions)). They name the command as its
  author wrote it and say which argument is the entity id; introspection and the golden name only
  the mutation field, and the golden exists only for this repo's examples. **Built the other way:
  introspection** ([§8](#8-what-was-built)).
- **SPQ3.** *Should a ReScript app be moved onto the generated adapter?* **Recommendation: no.** The
  hand-written adapter turns a renamed command field into a compile error; the generated one turns
  it into a refused mutation at run time. The equality check of [§5](#5-verify) keeps the two in
  step for the specimen.
- **SPQ4.** *Should the generated adapter be code generated at build time instead of a module at
  run time?* **Recommendation: at run time.** Generated ReScript helps only ReScript callers, who
  already have the typed path ([SPQ3](#7-open-questions)); a run-time encoder serves the file-based
  caller of [SP6](#sp6-commands-as-data-for-a-caller-without-rescript) and any language.

---

## 8. What was built

- **[SP1](#sp1-a-pace-held-by-the-client), [SP2](#sp2-a-pace-chosen-per-run).**
  [`Seed_Pace.res`](../../reventless/seed/src/Seed_Pace.res) reads `2s`, `500ms`, `30/min` and a
  trailing `~` for random gaps; [`Seed_Client.send`](../../reventless/seed/src/Seed_Client.res) waits
  on it before every command, chained so that concurrent senders keep it too. `SEED_PACE`, else the
  set's `pace`.
- **[SP3](#sp3-a-loop-repeats-a-follow-up-run), [SP4](#sp4-a-stop-that-waits-for-the-end-of-a-repetition).**
  [`Seed_Runner.play`](../../reventless/seed/src/Seed_Runner.res) plays a set `SEED_REPEAT` times or
  `forever`, and refuses at start a set that is not `repeatable` or that wants an empty store. The
  example's follow-up run is marked `repeatable`.
- **[SP5](#sp5-a-generated-adapter-read-from-the-command-definitions).**
  [`Seed_Commands.res`](../../reventless/seed/src/Seed_Commands.res) reads the domain API's
  introspection. The command definitions were the plan's choice; the build found three reasons
  against them: they are served on the platform API, not the domain API; only Admin may read them;
  and they leave out inbound translations, so `Catalog_ImportProduct` could not be encoded.
  Introspection has none of these limits and says all an encoder needs.
- **[SP6](#sp6-commands-as-data-for-a-caller-without-rescript).**
  [`Seed_Play.res`](../../reventless/seed/src/Seed_Play.res), offered by every seed entry through
  `SEED_FILE`; a mutation the API would refuse stops the run before anything is sent. A bin of its
  own was left out: a bin reads its arguments through `CliArgs`, which lives in `reventless-spec`,
  and adding that package to the seed's graph would reorder the root build. The specimen is
  [`traffic.yaml`](../../examples/online-shop-hybrid/seed-data/play/traffic.yaml).

**The checks of [§5](#5-verify)**, on an isolated local platform with a SQLite store:

- **Pace.** The follow-up played twice at `100ms` sent 43 commands in 4.9 s; unpaced, in 0.6 s. The
  file played three times at `1s` sent 15 commands in 14.6 s.
- **Same state.** A fresh store seeded `sample` and then the follow-up twice with no pace, compared
  with one that played the follow-up at `100ms`: 112 rows across five views, identical apart from
  recorded times and message ids.
- **Stop.** One SIGINT during the second repetition of a `forever` run: it finished, its growth
  checks passed, the run reported 2 repetitions and exited 0. Two SIGINTs: exit 130, naming the
  repetition cut short.
- **Adapter equality.** [`GeneratedAdapterTest.res`](../../examples/online-shop-hybrid/seed-data/tests/GeneratedAdapterTest.res)
  encodes every command the demo seed sends through both adapters, the generated one reading the
  committed SDL golden, and compares them.
- **Forward only.** The 42 events of the file run were recorded inside the run's window, in the
  order sent and one pace apart; each event's time is the platform's.

**Found on the way, not part of this plan:** on the in-memory backend, the `sample` seed set off a
loop in the outbound notification slice: one order's confirmation was sent more than 21,000 times
before the server stopped answering. The same seed on SQLite sent each mail a handful of times.
Fixed since: before translating, the slice rewrote its claimed row without the claim, and a pass
the in-process bus started during the send read that row as abandoned and sent it again. Each mail
now goes out once.
