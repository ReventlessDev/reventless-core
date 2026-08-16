# Plan: say where each lifecycle fact came from

**Status.** PLAN 2026-08-16. Not started. One new field per fact, following a
pattern this repo already ships twice, plus the consumer work that pattern was
introduced for.

**Goal.** A consumer reading a component definition can already tell whether
`labelField` was declared or guessed, and whether `idField` was declared or
guessed. It cannot tell that about anything to do with lifecycles — not which
field holds one, not where rows begin. Publish the rung, for the same reason the
other two publish it.

**Relates to:**

- `spec/Plugin.res` — `labelFieldSource` and `idFieldSource`, the pattern and its
  reasoning, which this plan copies rather than invents
- `lifecycle-transition-annotation.md` — the annotation whose declared edges are
  the "declared" rung here
- `backlog/lifecycle-terminal-state-vocabulary.md` — its open question 3 is the
  initial-state convention, which this plan makes visible without settling

---

## Why — two rungs are already published, the lifecycle's are not

`queryableDef.labelFieldSource` publishes one of `annotation | convention |
position | fallback`, and its doc comment gives the reason exactly: the rungs are
not equally believable, and a consumer with a naming rule of its own has to rank
the declaration against it. `idFieldSource` does the same with
`annotation | convention | sole`.

`lifecycleField` has the same shape and says nothing. Its documented resolution
order is: (1) a field annotated `@lifecycle`; (2) **a field literally named
`"lifecycle"` whose shape is an enum**; (3) `None`. Rung 2 is a guess of exactly
the kind the other two fields flag, and it is published indistinguishably from
rung 1.

Worth contrasting with `retiredField`, which is deliberately built with **no**
convention rung — its doc comment argues that a field named `archived` that
nobody annotated must not start hiding rows, because the cost of guessing wrong
is data disappearing. That is the right call there, and it is also the proof that
the rungs are being reasoned about one field at a time rather than uniformly.

## The second, quieter case: where rows begin

Two consumers take **the first declared enum member** as the initial state: the
lifecycle diagram, and the reachability lint that reports states nothing can
reach. Neither says so in the metadata, and nothing checks it.

The consequence is that reordering an enum silently changes what the platform
believes about an entity — which state is the start, and therefore which states
are reported unreachable. There is no annotation to get wrong and no error to
see. It is the least-reviewed load-bearing fact in the lifecycle model, and one
badge would put it in front of an author the first time they open a diagram.

## Shape

Two new optional fields, both following `labelFieldSource`'s conventions exactly
— string-valued, `option`, `js_nullable`, `None` meaning *not stated* rather than
*none found*, which is what keeps defs persisted before the field readable:

| Field | Rungs |
|---|---|
| `lifecycleFieldSource` | `"annotation"` (a field carries `@lifecycle`) · `"convention"` (a field named `lifecycle` with an enum shape) |
| `initialStateSource` | `"position"` (first declared enum member — the only rung there is today) |

The second looks odd with one rung, and that is the point: it publishes a fact
that is currently *implicit in two consumers* and belongs to neither of them. If
an explicit way to declare a start state ever arrives, it gains an `"annotation"`
rung and every consumer already reads the field.

**Not proposed:** a source for `commandDef.allowedStates` / `targetState`. Those
have exactly one rung — the author wrote a `@transition` or did not — so a
provenance field would carry no information. This is the same test that keeps the
set of annotations minimal, applied to the set of provenance fields.

## Steps

1. **Publish `lifecycleFieldSource`** alongside `lifecycleField` wherever that is
   derived, mirroring how `labelFieldSource` is set on the same pass. Add it to
   the admin GraphQL SDL and the JSON encoder in `Platform_ComponentDefinitionsApi`,
   both of which already carry `labelFieldSource` and `lifecycleField` and will
   show exactly where the new field goes.
2. **Publish `initialStateSource`**, and — the substantive half — move the
   first-member rule *into* the place that publishes it, so the diagram and the
   reachability lint read one derived fact instead of each re-deriving it. Two
   consumers independently applying the same convention is how they drift.
3. **Hand-rolled defs.** Both fields are `option` and both default to `None`;
   confirm nothing treats `None` as a rung rather than as silence.
4. **Tests.** A view whose lifecycle field is annotated reports `"annotation"`; a
   view relying on the name convention reports `"convention"`; a hand-rolled def
   reports `None`; and an enum reordered in a fixture changes `initialState` and
   is *visible* in the published def rather than only in a rendered diagram.

## What this unlocks, and why it is worth more than a badge

**A reviewable convention.** Step 2's fixture test is the first thing anywhere
that would notice an enum reorder changing where rows begin.

**A mechanical editor action.** A fact sourced from `"convention"` has one
obvious remedy — promote it to a declaration — and the edit writes itself: insert
`@lifecycle` on the field the convention guessed. The author reviews a concrete
proposal rather than authoring from a blank line. That inverts the usual adoption
problem with annotations: rather than asking for everything to be declared up
front, show what was inferred and let it be corrected, and each acceptance moves
one fact from guessed to declared. The editor half is not this plan's to build;
publishing the rung is what makes it possible.

## Risks

- **A field per fact is a wire change, and wire changes are the expensive kind
  here.** Both are additive and optional, which is the cheapest shape available,
  but plugin metadata has a size ceiling that has been hit before. Two nullable
  strings per queryable is small; the pattern generalising to a dozen is not, and
  the "one rung means no field" test above is what keeps it from doing so.
- **Publishing a rung invites a consumer to branch on it.** The value is in
  *display* and in the editor action, not in behaviour. A client that starts
  refusing to render a `"convention"`-sourced lifecycle has made the guess worse
  than it was when it was invisible.
