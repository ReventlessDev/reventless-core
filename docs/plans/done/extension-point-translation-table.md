# Plan: the port's translation table is part of the model — reflect it

**Status.** Implemented 2026-08-26. Shipped **derived**, not declared — see §3, which
records why the plan's own recommendation was overturned during implementation.

**Goal.** A plugin's structure already reflects every model fact a tool needs *except one*:
which internal event becomes which published protocol event at an extension point, and which
published event becomes which command at an extension. That mapping is the port's public
contract, and today it exists only inside a mapping function's body. Emit it onto
`extensionPointDef` / `extensionDef`, and check it.

**Relates to:**

- `lifecycle-transition-annotation.md` — the same shape of problem, one annotation over, and the
  precedent this plan followed until §3 was overturned: *declare the edge once, then check it*.
- `plugin-definition-schema-evolution-guards.md` — a new field on a persisted def is that plan's
  subject; §4 below is bound by it.

---

## §1 — What is missing, precisely

`extensionPointDef` carries two name LISTS and nothing that connects them:

```
sourceEventTypes : the Delegate's internal events that feed the port
(published events) : the EP spec's own `event` variants
```

The connection lives in `mapOutgoingEvent`, typed
`(id, Delegate.event, meta, queryEngine) => array<action<EP.event, EP.directive>>`
(`infra/src/types/ExtensionPointMapping.res`). A `switch` over the delegate's constructors,
each arm returning `PublishEvent(id, EP.SomeEvent(…))`.

Three properties make the two lists unjoinable from outside:

1. **The names are unrelated.** The port renames deliberately — that is what a port is for. A
   subscriber's vocabulary is not the provider's.
2. **The relation is many-to-one, by design.** In `online-shop-hybrid`, `ProductArchived` and
   `ProductDiscontinued` both publish `ProductWithdrawn`; the mapping's own comment says the
   Catalog's two retirements "collapse into the one fact a subscriber needs." Five internal
   events publish as four. No positional join exists either.
3. **It is a function body**, so nothing that reads a definition can see it.

The subscriber side is the mirror image and equally invisible: `mapIncomingEvent` turns published
events into the subscriber's commands, and `extensionDef` carries `eventTypes` and
`delegateNames` with no edge between them.

## §2 — Why this is worth doing on its own terms

Not "a tool wants it". Three framework-level consequences:

- **The port's contract is unreviewable.** The one artefact a subscriber integrates against is
  the only part of the model no reflection can render, diff or document. `GraphDiff` compares
  source and deployed graphs and cannot see a rename that changes what a port publishes.
- **Two defect classes are undetectable at build time.** A published event **no arm produces**
  is dead protocol surface a subscriber may already be routing. An internal event **no arm
  publishes** is silently swallowed at the port.
- **Any structure consumer must guess or give up.** Both are worse than the truth. A consumer
  that joins the two lists by name gets an answer that is *wrong wherever the port renames* —
  and, where one name happens to survive the port unchanged, wrong in a way that looks measured.

## §3 — How to get it: **derived from the arms** (plan overturned in implementation)

The plan as written recommended an explicit declaration checked against a probe. That was built,
and then **rejected on review**: every edge cost the author two hand-typed strings that the
compiler could not check against anything, in a table that a rename would silently make stale.
The rejection of AST inference below assumed inference would be the *sole* source with no signal
where it fails — and that assumption is what turned out to be wrong.

### What ships: the PPX reads the table off the arms

`packages/reventless-ppx/src/ppx/TranslationTable.ml` walks the mapping's own `switch`:

- **`publishedEvents`** from `mapOutgoingEvent` — the arm pattern's constructors are the sources,
  `PublishEvent(_, EP.X(…))` in the body is the target.
- **`handledEvents`** from `mapIncomingEvent` — `PublishAggregateCommand` /
  `PublishStateChangeSliceCommand` / `PublishExtensionPointCommand` name the target.

Which side a module is on is read off its inbound function, the way the two module types differ:
an extension maps incoming *events*, an extension point maps incoming *commands*. It fires on the
app conventions (a `*ExtensionPointMapping.res` file whose mapping is the file, an
`@@reventless.extension` file's `module Mapping`) and, through a nested walk, on a mapping
declared as an inner module — inside a functor, or handed anonymously to `Make`, which is how the
framework's own ports and the test fixtures are written.

Names are the constructors the compiler already checked, so a typo is impossible; many-to-one
falls out of two arms publishing the same event; a fan-out through `Array.map` is read through
the lambda; an arm publishing nothing contributes no row.

**Completeness is not assumed — it is enforced.** The walk accepts only shapes it can read to the
end: array/list literals of action constructors, `if` / nested `switch` / `let` in tail position,
and combinators over a lambda (the `->` pipe included). Anything else — `PublishEventAsync` and
the `*Async` command forms (the message is behind a promise), `ForwardCommand` (opaque JSON), an
opaque helper call, a wildcard arm that publishes — **fails the build naming that arm**:

```
reventless: cannot read publishedEvents from this arm — `PublishEventAsync` hides what it
publishes behind a promise. Write the table by hand (`let publishedEvents = [...]`) and this
derivation steps aside.
```

That inverts the original objection: an incomplete table is impossible, because the PPX either
reads an arm or refuses to compile. "No edge" and "did not look" never read alike.

### The escape hatch, and what still checks it

A file that declares `publishedEvents` / `handledEvents` itself keeps them and the derivation
steps aside. Nothing in the repo needs it today — the nested walk reaches every mapping here — so
the hatch exists for the shapes §3 refuses to read. A hand-written table is checked at
plugin-structure assembly, and that check is the surviving half of the original plan:

- **Names** — every declared published name is a real EP `event` variant, every source a real
  `Delegate.event` variant, every routed command a real delegate or EP command. Total, and it
  raises.
- **The probe** — one synthesised event per Delegate constructor, run through the author's own
  `mapOutgoingEvent`. An edge the probe saw and the table omits **raises** (it watched the arm
  publish it); an edge declared but not seen only **warns** (the arm may branch on a payload the
  probe cannot synthesise). A constructor the probe could not follow is judged not at all and
  reported with the reason, never counted as publishing nothing.

### Rejected: probe-only, with no declaration and no PPX

The probe alone cannot see an async arm or the other side of a payload branch, and it executes
user code with fabricated input. It is the right *cross-check* on a hand-written table and the
wrong *source*.

## §4 — What was built

1. **Vocabulary.** `publishedEventDef` on `extensionPointDef`, `handledEventDef` on
   `extensionDef`, both `js_nullable` per the `commandTypes` precedent (a sury field cannot be
   both absent-tolerant on decode and JSON-encodable, and these defs are nested in the
   JSON-encoded lifecycle `Message` union). Always written, read with `->Option.getOr([])`;
   definitions persisted before the field must be re-emitted.
2. **Declaration site + `Plugin_Structure` emission.** `publishedEvents` on
   `ExtensionPointMapping.Mapping`, `handledEvents` on `ExtensionMapping.Mapping` (and carried
   through `Make` onto `T`, with `delegateCommandNames`, because `Plugin_Structure` sees an
   extension only compiled). Emitted beside `sourceEventTypes` / `delegateNames`, qualified to
   match the sibling lists: published events by EP name, source events by plugin name, a delegate
   command by plugin name and a command sent back to the port by EP name.
3. **The PPX derivation** (§3) plus the checks that stand behind a hand-written table.
4. **Served.** `Platform_PluginStructuresApi` / `Platform_ComponentDefinitionsApi`, with
   `Platform_PublishedEventDef` / `Platform_HandledEventDef` in the SDL; goldens refreshed.
5. **Swept the repo.** All six mappings and all six extensions across the three shops, the
   framework's own three ports (the lifecycle port, its UI-fragment sibling, and the connect
   extension), and the GWT / local test fixtures derive their tables. Not one needed a
   hand-written line.

**Dropped from the plan: `swallowedEventTypes`.** The declared version needed a way to say "this
internal event deliberately publishes nothing", because a hand-written table could not distinguish
a deliberate omission from a forgotten one. A derived table can: the arms *are* the statement. The
field was built, then removed with the declaration it existed to defend.

## §5 — What this found

- **`PluginExtensionPointSpec.PluginReconnected` is dead protocol surface.** It is declared on the
  platform's own lifecycle port and no arm publishes it — precisely the first defect class §2
  predicts, surfaced by the check's first run. Left as a warning: removing a variant from a
  published protocol is a breaking change for a subscriber compiled against it, and belongs in its
  own change.

## §6 — Risks

- **A derived table is only as complete as the walk.** Mitigated by refusing to compile rather
  than guessing, and by the PPX test suite covering many-to-one, fan-out, a swallowing arm, an
  unreadable arm, and the hand-written escape hatch.
- **The PPX binary and the source must agree.** This repo's CI, Release and deploys build the PPX
  from source, so a mapping compiles correctly here in one commit. An **external** consumer
  installs the published per-platform binary, and an older one silently emits no table at all —
  which is a missing field, not a wrong one, but republish `reventless-ppx` in lockstep anyway.
- **The re-emit in §4.1.** Every persisted plugin definition must be re-emitted before a consumer
  can read the new fields as present. Sequence it with the guards plan rather than separately.
