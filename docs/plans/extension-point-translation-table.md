# Plan: the port's translation table is part of the model — reflect it

**Status.** Proposed 2026-08-26. Not started.

**Goal.** A plugin's structure already reflects every model fact a tool needs *except one*:
which internal event becomes which published protocol event at an extension point, and which
published event becomes which command at an extension. That mapping is the port's public
contract, and today it exists only inside a mapping function's body. Emit it onto
`extensionPointDef` / `extensionDef`, and check it.

**Relates to:**

- `lifecycle-transition-annotation.md` — the same shape of problem, one annotation over, and the
  precedent this plan follows: *declare the edge once, then check it*. Its opening complaint is
  exactly ours — the pair was "unchecked in both directions: a misspelled state name compiles
  clean and mis-filters a command menu forever."
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
  publishes** is silently swallowed at the port — indistinguishable from a deliberate omission,
  which is precisely why it needs to be declared rather than inferred.
- **Any structure consumer must guess or give up.** Both are worse than the truth. A consumer
  that joins the two lists by name gets an answer that is *wrong wherever the port renames* —
  and, where one name happens to survive the port unchanged, wrong in a way that looks measured.

## §3 — How to get it: declare, then check

### Rejected: infer from the AST (PPX walk over the `switch` arms)

Attractive because it costs the author nothing. Rejected because it cannot be complete, and an
incomplete table is worse than none — a consumer cannot tell "no edge" from "the PPX did not
follow that arm". Guards, a helper function, a conditional, or a `PublishEventAsync` (whose
event is behind a promise) each defeat it silently.

### Rejected: probe at build time (call `mapOutgoingEvent` with a synthetic event per variant)

There is precedent for executing model functions to harvest facts, and `@schema` can synthesise
a value per variant. But the mapping takes a `queryEngine` and may branch on the payload, so a
probe reports one arm of a payload-dependent mapping as the whole truth, and an async arm not at
all. Same failure mode as the AST walk: silently partial.

### Recommended: an explicit declaration on the mapping, checked against a probe

The declaration is authoritative and always complete; the probe is a **best-effort check**, not
the source. This is the `@transition` bargain, and it inverts the failure mode — a stale
declaration is caught where it can be caught, and where the check cannot run the author's
statement still stands rather than the tool's silence.

Shape (per PUBLISHED event, so many-to-one is the natural case and "produced by nothing" is
representable):

```
publishedEvents: [
  { name: "ProductBecameAvailable", fromEventTypes: ["ProductAdded"] },
  { name: "ProductWithdrawn",       fromEventTypes: ["ProductArchived", "ProductDiscontinued"] },
  …
]
```

An empty `fromEventTypes` is a legitimate declaration (published from an async or derived path),
distinct from the event being absent from the list entirely.

## §4 — Phases

1. **Vocabulary.** `publishedEvents` on `extensionPointDef`; the mirror (`handledEvents`,
   published event → the commands it routes to) on `extensionDef`. **Bound by the
   `commandTypes` precedent already documented on `extensionPointDef`:** a sury field cannot be
   both absent-tolerant on decode and JSON-encodable, and these defs are nested in the
   JSON-encoded lifecycle `Message` union — so `js_nullable` (`T | null`), always written, read
   with `->Option.getOr([])`, and definitions persisted before the field must be re-emitted.
2. **Declaration site + `Plugin_Structure` emission.** Populate from the declaration in
   `extensionPointDefs` / `extensionDefs`, beside `sourceEventTypes` and `delegateNames`.
3. **The check.** At build: every declared `fromEventTypes` name is a real `Delegate.event`
   variant and every declared published name a real EP `event` variant (this part is total —
   both are `@schema` types). Then the probe where it can run, reporting a declared edge no arm
   produced and an arm producing an undeclared edge. Skip with a stated reason for an async or
   payload-branching mapping rather than passing it silently.
4. **Serve it.** `Platform_ComponentDefinitionsApi` / `Platform_PluginStructuresApi` — the two
   places that already encode these defs.
5. **Sweep the examples**, which is also where the design meets reality; expect at least one
   mapping the check cannot verify, and record why rather than weakening the check.

## §5 — Risks

- **Authoring burden, and the reason to accept it.** Every EP mapping gains a declaration that
  duplicates what its arms already say. That duplication is the point — it is what makes the
  arms *checkable*, and `@transition`'s history is the argument: the version without the check
  let a misspelling compile clean and stay wrong indefinitely.
- **A silently partial check reads as a passing one.** Whatever §3 concludes, a mapping the
  probe cannot follow must SAY so. This plan is about not confusing "no edge" with "did not
  look"; a check that makes the same confusion one layer up would be self-defeating.
- **The re-emit in §4.1.** Every persisted plugin definition must be re-emitted before a
  consumer can read the field as present. Sequence it with the guards plan rather than
  separately.
