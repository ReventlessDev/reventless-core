# Plan: the seed becomes a player, and generates its own adapter

**Date:** 2026-09-20
**Status:** Proposed — not started.

Extends [`ReventlessSeed`](../../reventless/seed/src), which already does the hard and
correct part: it builds mutations from typed domain commands and sends them **through the
public GraphQL API**, with
[`Seed_Connect.local`](../../reventless/seed/src/Seed_Connect.res) defaulting to
`http://localhost:4000/graphql`. Going through the front door is the property everything below
depends on, and nothing here weakens it.

Related: [online-shop-seed-over-days.md](online-shop-seed-over-days.md) — a different problem
(one domain's multi-day narrative), but the source of the constraint in §2.

---

## 1. Two gaps

**It is a batch loader, not a player.** A run builds a list and sends it in phases. There is no
time dimension: no delay between sends, no loop, no stop. A seeded system therefore arrives
fully-formed, which is exactly wrong for watching a live view update, for exercising an
automation that reacts to arrivals, or for any demonstration that a system is *running* rather
than *populated*.

**The adapter is the caller's to write.** `Seed.res:6` states it plainly: *"the mapping from a
plugin's command types to `mutation` values is the caller's adapter."* That is the right
factoring for a framework and the wrong requirement for anyone who is not writing ReScript.
The mapping is mechanical and the information needed to generate it is already introspectable
from the deployed schema — the same schema a generated command form is built from.

---

## 2. The constraint that shapes this: forward only

[online-shop-seed-over-days.md](online-shop-seed-over-days.md) puts backdating explicitly out
of scope, on a stated design ground: *"It would turn the recorded time into a claim made by the
caller, and automations would still react at today's time, so a backdated order's trail would
read out of order."*

**That refusal stands, and this plan states it up front rather than rediscovering it.** A
player plays *forward*, compressing the intervals between events rather than stamping them into
the past. "An hour of traffic" is a shape — arrival rate, ordering, concurrency — not a set of
timestamps. Anything wanting real historical timestamps is asking for a different mechanism
than a seed, and should be told so rather than accommodated here.

---

## 3. What

### 3.1 A time dimension

1. **Delays between sends**, expressed as the schedule of a run rather than sprinkled through
   its steps, so a run can be replayed faster or slower without editing it.
2. **A loop**, for traffic that should continue until stopped rather than terminate.
3. **A stop** that is not a killed process: a running player is asked to finish, and it stops
   at a point where the domain is consistent.
4. Phases stay. They are the existing ordering primitive and a schedule composes with them.

### 3.2 A generated adapter

Generate the command-type → mutation mapping from the introspected schema instead of requiring
it to be hand-written. The facade keeps the hand-written path — a caller with an adapter is not
made to regenerate one — and gains a generated default for callers who have only a running
endpoint.

**The generated adapter goes through the same front door.** It is a convenience for producing
`mutation` values, not a second way in.

---

## 4. Anti-requirement

**Never write rows into a read model to make a view look busy.** A player exists to produce
real traffic; a view populated behind the domain's back hides precisely the defects a seeded
run is worth having. If the player cannot produce a state through commands, that is a finding
about the domain, not a reason to fake the state.

---

## 5. Verify

- A run with a schedule takes the wall-clock time its schedule implies, and the same run with
  the schedule removed produces an identical final state.
- A player looping is stopped cleanly and leaves no half-finished workflow.
- A generated adapter and a hand-written one for the same plugin produce the same mutations.
- No event carries a caller-claimed time. §2 is checked, not assumed.

## 6. Out of scope

- **Backdating.** §2. Not deferred — refused.
- **Scheduling a player run.** Starting it is a separate concern, as the sibling plan says of
  its own follow-ups.
- **A UI for it.** The surface that offers this to someone who is not running a CLI belongs
  wherever that surface lives; this plan makes it possible and stops.
