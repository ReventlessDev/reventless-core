# Backlog: `TimeOfDay` — a wall-clock time as a semantic type

**Status:** Backlog, and deliberately so. This is not "small, do it later" — it is blocked on one
decision the framework has never had to make (§ *Blocker 1*), and on a grammar that does not exist
to borrow (§ *Blocker 2*). Both are stated here so that whoever picks it up starts from the
decision rather than from the module.
**Deferred from:** [semantic-date-time.md](../done/semantic-date-time.md) § D6, which introduces
`DateTime` and `CalendarDate` and explains why the third member of the trio does not follow them.
**Prior art:** [done/semantic-branded-scalars.md](../done/semantic-branded-scalars.md) — the module
template and the one-grammar rule this type cannot currently satisfy;
[semantic-date-range.md](../semantic-date-range.md) — the composite template, and its *Out of scope*
entry on named zones, which is the same wall this hits.

## What it would be

A field whose value is a reading on a clock face — `09:00`, `17:30` — with no day and no instant
attached. Shop opening hours, a daily dispatch cutoff, the time a digest goes out, a delivery slot
expressed as "mornings".

Distinct from both types the parent plan lands: `DateTime` is an instant (a point on the world's
timeline, UTC), `CalendarDate` is a day (no time at all). A time of day is neither — it recurs, and
it is the only one of the three whose meaning depends on somewhere being named.

## The state of play

**The repo already has one, positionally.**
[reventless/spec/src/types/Schedule.res](../../../reventless/spec/src/types/Schedule.res) expresses
a daily firing time as an int pair:

```rescript
| Daily(hour, minute)              // fires every day at the given UTC time
| Weekdays(hour, minute)
| WeekdaysAndSaturday(hour, minute)
```

That is exactly the shape `GeoPoint` and `DateRange` were built to replace — two scalars plus a
convention holding them together, with the zone rule ("UTC") living in a doc comment rather than in
the value. It is also *deploy-time configuration* that compiles to a cron expression, not a domain
field on a row, so it is a candidate first adopter with a caveat: adopting it would change a
schedule's wire form, and the cron emitter reads the pair directly. Worth doing, but not the same
job as putting the type on a view.

**Nothing carries a zone.** A grep of `reventless/spec/src` and `reventless/core/src` for
`timezone` / `time zone` / `tzid` / `IANA` returns nothing at all. The notification trait already
recorded this from the other side — "Nothing in the framework carries a recipient timezone, so 'a
`dateTime` in the recipient's zone' had no input to read"
([trait-notification.md:317](../trait-notification.md#L317)) — and the date-range plan put named
zones out of scope for the same reason.

**The UI has no reader.** `AutoSemantics` parses no time semantic, and `format: "time"` is not
handled anywhere in `reventless-ui/reventless/ui/src`. The only near-match is a *name* heuristic
(`AutoLifecyclePath.stampSuffixes` includes `"time"`), which is the kind of guess a semantic type
exists to retire, not a renderer.

## Blocker 1 — where does the zone live? (a decision, not a task)

A wall-clock time is unusable without something saying whose clock. `09:00` on a row means nothing
until a reader knows it is the store's local time, or the viewer's, or UTC. This is the decision
that shapes everything else, and it has at least four answers, none of which the framework has
picked:

- **UTC by fiat**, as `Schedule` does today. Simple, honest at the boundary, and wrong for the
  motivating cases — a shop does not open at 08:00 UTC, it opens at 09:00 and the offset moves twice
  a year. Picking this makes the type a thin brand over the existing convention and leaves the real
  problem unsolved.
- **A zone beside the time, per row** — the value becomes a composite (`{time, zone}`), not a branded
  scalar, and the plan changes template from `Email` to `Money`. This is probably right for opening
  hours, where the zone belongs to the *place* rather than to the deployment.
- **A zone on the platform or the plugin**, resolved at render time. Cheapest for a single-region
  deployment, wrong the moment two are in one platform, and it is deployment configuration reaching
  into value semantics — the boundary §3 of the semantic analysis draws.
- **A zone on the viewer's identity**, resolved per request. Answers "when does my digest arrive"
  and answers nothing about opening hours. Also the largest of the four: it touches identity,
  authorization context and every renderer.

**These are not mutually exclusive and that is the trap** — a row's zone and a viewer's zone answer
different questions, and a design that conflates them produces a type whose meaning changes with who
is looking. Decide which question `TimeOfDay` answers *before* writing the module.

Suggested framing when this is picked up: the value's zone is the *subject's*, and the viewer's zone
is a presentation concern belonging to the reader. That makes the composite (`{time, zone}`) the
likely shape and leaves the viewer half out of scope — but it is a decision to take deliberately,
with the notification trait's use case in front of you, not a default to inherit from this
paragraph.

## Blocker 2 — there is no grammar to borrow

Every other member of the family borrows its rule from somebody else, and the branded-scalars plan
makes that a rule of its own: "Never hand-roll a second regex in the factory." sury's `isoTime`
does not fit. Probed against the pinned `sury@11.0.0-rc.2`:

```
accept "09:00:00Z"        accept "09:00:00+01:00"
reject "09:00:00"         reject "00:00:00"        reject "23:59:59"
reject "09:00:00.000"     reject "9:00:00"         reject "T09:00:00"
```

It requires an offset — it is RFC 3339 `full-time`, an instant *within* a day, which is the one
thing a wall clock is not. So the options are:

1. **Hand-roll `HH:MM[:SS]`.** Small and well-understood, but it needs an explicit exemption from
   the one-grammar rule, written down with its reason, or the next person removes it as an
   inconsistency.
2. **Upstream a `localTime` to sury.** Correct, slow, and out of this repo's control.
3. **Accept `isoTime` as-is** and admit the type is an offset-bearing time. Cheapest, and it
   answers none of the motivating cases — see Blocker 1's first bullet for the same failure.

**Also worth resolving first:** `isoTime` rejecting `"09:00:00.000"` looks like a sury bug (a
fractional second is valid RFC 3339, and `isoDateTime` accepts one). Confirm it upstream before
building anything on that schema — if it is a bug, option 3's cost changes, and if it is not, that
is itself an argument the schema is modelling something narrower than it appears to.

## Blocker 3 — a real adopter, and the reader before it

The family's standing rule, from `GeoPoint` onwards: a semantic type lands with a field that
genuinely needed it. A contrived example is worse than none, because it fixes the type's shape
around a case nobody has. Candidates, in the order they are likely to become real:

- **`Schedule.rate`'s `(hour, minute)` pairs** — exists today, but see the caveat above.
- **Opening hours / availability windows** — the motivating case, and the one that forces Blocker 1
  to the row-level answer. Note this is a *range* of times, so it may want a `TimeOfDayRange` the
  way `DateRange` pairs instants — decide whether the scalar ships alone or the pair ships with it.
- **A daily cutoff on a fulfilment or notification rule** — the notification trait would be its
  natural home once that trait carries a zone.

And the reader ships first, per the union lesson recorded in CLAUDE.md: the UI shell reads schemas at
runtime, so an open tab breaks the moment the SDL changes. `format: "time"` (or the semantic id,
whichever the emission decision lands on) needs a renderer and a form input in `reventless-ui`
**before** the first adopting view, not with it.

## What running this plan would then look like

Short, once the three above are settled — which is the point of listing them:

1. `semantic/TimeOfDay.res` on the family template — `type t`, `grammar`, `fromString`, `schema`
   via `Semantic.refined`, `format`, plus `compare` with an explicit answer to whether a window may
   wrap midnight (`22:00`–`02:00` is a real opening hour and a scalar comparison says it is empty).
2. A new `Semantic.Id.timeOfDay`, and the emission decision: standard `format: "time"`, the semantic
   key, or both — mirroring the asymmetry the parent plan documents for `CalendarDate` in its step 7.
3. The composite, if Blocker 1 resolves to a per-row zone.
4. The adopter, and the goldens that move with it.
5. Tests on the family pattern: the grammar's accepts and rejects pinned as decisions, the emission
   block, and the midnight-wrap behaviour whichever way it was decided.

## Out of scope even when this runs

- **Recurrence.** "Every second Tuesday at 09:00" is a rule that generates times, not a time — the
  same line `DateRange` draws against `RRULE`.
- **A viewer-local rendering pipeline.** Formatters here are locale-independent by standing rule
  (`Money.format` states it, every formatter since repeats it); rendering a stored time in a
  reader's zone is the presentation layer's job and stays there.
- **Retrofitting `Schedule`.** If it adopts the type, that is its own change with its own wire and
  cron-emitter consequences.
