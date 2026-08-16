# Plan: declare the lifecycle edge once — `@transition` and the check the PPX cannot make

**Status.** PLAN 2026-08-16. Not started. Four phases, of which the first two
want to land in one release because the first is breaking and the second is the
reason the first is worth doing.

**Goal.** Replace the `@allowedStates` / `@targetState` pair with a single
`@transition` annotation that says the whole edge, and then *check* it — at
build time, against the lifecycle enum the linked view actually declares. Today
the pair is unchecked in both directions: a misspelled state name compiles clean
and mis-filters a command menu forever.

**Relates to:**

- `done/command-state-guards-allowed-states.md` — the original design. Its
  witness binding was dropped during implementation and its validation was
  deferred to "platform start"; both holes are what §2 and §3 close.
- `retired-marks-the-state-not-the-field.md` — the same class of bug, found and
  fixed one annotation over. Its argument ("on the constructor the name cannot
  be wrong, because it **is** the declaration") is the argument here, and §1
  explains why this annotation cannot take that route.
- `backlog/command-applicability-when-retired.md` — overlaps §4's guard-only
  sweep. This plan supplies the *authoring* answer; that plan still owes the
  *default* answer for unannotated commands. Neither blocks the other.
- `order-line-items-and-totals.md` — rewrites the same hybrid ordering slice §4
  touches. See §7.

---

## Why — two annotations for one fact, neither of them checked

A state-guarded command declares its edge twice today, in two attributes that
know nothing about each other:

```rescript
| @allowedStates([Orders.Placed])
  @targetState(Orders.Shipped)
  ShipOrder({orderId: string})
```

`AllowedStatesAnnotation.ml` and `TargetStateAnnotation.ml` are 212 and 168
lines that differ only in arity — the same `find_attr` / `leaf_of_lident` /
`parse_payload` / `extract_variant_entries` / `gen_metadata_binding` /
`strip_from_constructor` / `transform` skeleton, walked twice over the same
structure from two consecutive lines in `ReventlessPpx.ml`:

```ocaml
let body = AllowedStatesAnnotation.transform ~loc body in
let body = TargetStateAnnotation.transform ~loc body in
```

Both lower onto `ReventlessInfra.Api.markAllowedStates` / `markTargetState`,
which `Plugin_Structure` reads back per variant into `commandDef`. The
duplication is not the real cost, though. The real cost is that **neither name is
ever checked against anything**.

### The hole is documented in the source that has it

`AllowedStatesAnnotation.ml` carries the post-mortem in a comment:

> Witness bindings (`let _ = Module.Constructor`) were considered to give
> compile-time existence checks on the referenced constructors, but PPX-emitted
> bindings are not visible to ReScript's dep analysis (which runs pre-PPX). […]
> Dropping the witness: typos in the input now go undetected at compile time.
> Future work: surface a runtime validation at platform start that cross-checks
> each `allowedStates` array against the corresponding read model's status-field
> schema.

That future work was never done. So `@allowedStates([Orders.Plcaed])` compiles,
ships, and produces a command that is legal in a state no row is ever in — a
menu entry that never appears, with nothing anywhere saying why.

`@targetState` is worse, because it advertises leniency: its `parse_payload`
accepts `Pexp_constant (Pconst_string …)` as well as a constructor, and the
module comment says the value is validated "at registration". It is not — no
such check exists. The one place in this repo that uses the string form is our
own PPX fixture, `tests/plugin/StateChangeSlice/PsShipOrder.res:22`.

**This is the same shape `retired-marks-the-state-not-the-field.md` closed**: a
stringly-typed reference to a constructor, stripped before the typechecker sees
it, landing in the schema looking like enforcement. That plan's fix — move the
annotation onto the constructor so the name *is* the declaration — is not
available here, and the difference is worth stating precisely, because it is the
whole reason this plan is bigger than that one was.

`@retired` marks a state of an enum **declared in the same file**, so the
constructor is in scope and the attribute can ride on it. `@transition` names
states of *another component's* lifecycle — `Orders.Placed`, declared in the
view. A command variant cannot be attached to a constructor it does not own, and
the witness comment above explains why a synthetic reference to it does not
survive ReScript's pre-PPX dependency analysis. **The name can only be checked
where both sides are in hand, which is not the PPX.** Hence §3.

---

## Non-goals

**Not renaming the lowered metadata.** `commandDef.allowedStates` and
`commandDef.targetState` keep their names and their shapes. They are the wire —
`Plugin_Structure`, `ApiAllowedStatesHelpers`, `ApiTargetStateHelpers`,
`spec/Plugin.res`, `infra/Api.res` and every consumer downstream read them.
Renaming them buys nothing and breaks everything.

**Not deprecating the old pair — removing it.** See §2.

**Not superstates.** `DiscontinueProduct`'s `[Listed, Archived]` spelled out is
fine at this domain size. Hierarchy earns its complexity when a real domain
repeats a from-set across many commands; none here does.

**Not a state machine library, and not a runtime.** `@transition` lowers to the
metadata that already exists. Nothing gains a machine, an interpreter, or a
persisted machine snapshot.

---

## §1 — The surface

Two forms, one attribute:

```rescript
| @transition(([Orders.Placed]) => Orders.Shipped)   // moves the row
  ShipOrder({orderId: string})

| @transition([Customers.Active])                   // guards, does not move
  UpdateEmail({customerId: string, email: string})
```

Brackets are mandatory on the from-set even for one element, so the two forms
are told apart by the presence of the arrow rather than by the shape of the left
operand.

**The one-sided form is a positive claim, not an omission.** It says *this
command does not move the row*. That distinction is already representable on the
wire — `allowedStates: Some(_), targetState: None` differs from
`allowedStates: None, targetState: None` — and consumers are expected to honour
it. This plan only produces the declaration; what a consumer does with it is
that consumer's own plan.

**Decision — the string form is dropped.** `@targetState("Shipped")` accepted a
bare string "for leniency"; `@transition` accepts constructor references only. A
string state name is exactly the unguarded path
`retired-marks-the-state-not-the-field.md` closed, and keeping it would leave
§3's validator a case it cannot check meaningfully. The one fixture that uses it
(`PsShipOrder.res`) grows a real lifecycle enum in §2 instead.

---

## §2 — Phase 1: `@transition` in the PPX, and the old pair removed

**New `TransitionAnnotation.ml`**, replacing both modules at their two call
sites in `ReventlessPpx.ml` with one. One traversal instead of two over the same
structure; it emits both `markAllowedStates` and `markTargetState` rebindings
from a single pass, chained in that order so the existing lowering is unchanged
downstream.

**The parse is new code, not a copy — and the AST is not what it looks like.**
`AllowedStatesAnnotation.parse_payload` walks an *expression* — `Pexp_array` of
`Pexp_construct`, with an OCaml-list fallback. The arrow form needs a different
walk, and three facts about it were established by building it rather than by
reading the parser. All three are silent failures if guessed wrong.

**(a) The from-set must be parenthesised.** ReScript's parser rejects a bare
`@transition([A] => B)` outright — "I'm not sure what to parse here when looking
at `=>`". An array is not accepted as a bare arrow parameter. The surface is
therefore:

| Form | Surface |
|---|---|
| moves the row | `@transition(([Orders.Placed]) => Orders.Shipped)` |
| guards only | `@transition([Customers.Active])` |

Slightly noisier than the one-sided form, and worth it: the extra parens are the
price of the arrow reading as an arrow.

**(b) The arrow does not arrive as `Pexp_fun`.** ReScript wraps it in its
uncurried marker first, so the payload is
`Pexp_construct (Function$, Some (Pexp_fun …))` carrying `[@res.arity 1]`. The
marker must be unwrapped before matching the function — and unwrapped **by
name**, because the OCaml list form is also a `Pexp_construct` (`::`) and a
generic constructor unwrap eats it.

**(c) The target is not a one-element list.** Running it through the from-set's
list walk reports a "must be bracketed" error on a target that must *not* be
bracketed. It needs its own single-state extractor.

| Form | Payload AST after unwrapping | Extractor |
|---|---|---|
| arrow | `Pexp_fun (_, _, Ppat_array [Ppat_construct …], Pexp_construct …)` | new pattern walk for the from-set, single-state walk for the target |
| one-sided | `Pexp_array [Pexp_construct …]` | the existing expression walk, unchanged |

Pin all three in tests before writing the lowering — a mis-read of the arrow
form fails by producing an empty from-set, which is silent.

**The old attributes are removed, and their removal is loud.** `@allowedStates`
and `@targetState` are deleted, and in their place a stub raises a build error
naming `@transition`. Silently ignoring a leftover attribute would reproduce the
stale-metadata failure mode in a new place — the author would believe a guard
was declared and there would be none. This is alpha; there is no back-compat
obligation, and carrying two spellings of one concept is the duplication this
work exists to end.

**Consequence: this phase breaks the repo, and repairs it in the same commit.**
Everything carrying either attribute must convert or the build stops. That is
15 sites in the examples (§4) plus **this repo's own PPX fixture**:

- `tests/plugin/StateChangeSlice/PsShipOrder.res:22` — `@targetState("Shipped")`,
  the string form, in a fixture with no lifecycle enum for a constructor to
  name. It gains one, per §1's decision.
- `tests/plugin/PluginStructureTest.res:236` — the assertion naming it, whose
  test name quotes the old spelling.

These two are not part of §4's sweep. They are this phase's own repair, because
the hard error fires the moment the stub lands.

**Exit.**

- PPX unit tests cover both forms, both error paths (malformed payload, arrow
  with a non-array left), and the removed-attribute error.
- `PsShipOrder.res` declares a lifecycle enum and uses the constructor form;
  `PluginStructureTest.res` still asserts the value flows through to
  `commandDef.targetState`.
- **No `@allowedStates` or `@targetState` attribute application remains anywhere
  in the repo outside `examples/`** — verified by grep over non-comment lines.
- A release the examples can pin.

---

## §3 — Phase 2: the check the PPX cannot make

This is the phase that makes the rename worth more than a rename. Land it in the
same release as §2.

**The rule.** Every state name in a `@transition` must be a declared member of
the linked view's lifecycle enum — including its `@retired` members, which are
states like any other.

**Where it goes, and the precedent it follows.** `Plugin_Structure` already does
exactly this shape of check one annotation over. `checkRetiredValue` (line 120)
resolves the entity's lifecycle field, reads the enum members out of the state
schema, and reports each `@retired` value the enum does not declare. Its own
comment states the principle this phase generalises:

> The check the PPX cannot make, in the one place that can: the payload is a
> constructor reference the PPX only ever sees as a name, and whether that name
> is a case of the field's enum needs the schema.

The new check is that function's sibling, reusing `lifecycleFieldFromStateSchema`
and the same enum extraction, applied to command from-sets and targets instead of
the retired field.

### Three things the precedent does not settle

**(a) Where the failure happens — CORRECTED, and simpler than first written.**
This plan originally said the check could not raise, on the grounds that
`Plugin_Structure` is reached from `Plugin_Builder` and therefore from a
deployed Lambda. **That was wrong**, and it was wrong because the claim came
from a grep that matched *comments* in `PluginRuntime_Builder.res` rather than
calls. Traced properly:

- `Plugin_Builder.Make` is instantiated by `aws/src/components/Plugin.res`,
  which calls `Pulumi.Pulumi.getProjectName()` at module level — the deploy
  program. It could not load in a Lambda at all.
- The Lambda side (`Platform_ComponentDefinitions_Lambda_Ops`) **reads a
  persisted structure and decodes it**; it never builds one.
- The only other caller is `local/src/Platform.res`, the local dev platform.

So `Plugin_Structure.make` runs at deploy and at local-platform start, and
nowhere else. **A raise there is a failed deploy, which is precisely the
intended behaviour** — no "two callers, two dispositions" machinery is needed,
and the plan is better for not having built it.

Still true, and still the reason the check lives here rather than in the PPX:
`Plugin_Structure` had no hard-fail before this (four `log.warn`, no `raise`).
Adding the first one is a deliberate change to what a malformed plugin does at
this stage, from "logs and continues" to "stops".

**(b) The linked view may not be singular.** `linkedViews` is an array, built
from `linkedSvsFor(produced)` and `linkedReadModelsFor(…)` (`Plugin_Structure`
lines ~929/953). "Resolve the linked view" is therefore under-specified. Rule:
check each state name against the **union** of the lifecycle enums of all linked
views that declare one. A name found in any of them passes. Rationale: a command
whose slice feeds two views is not making a claim about which one, and failing a
build on an ambiguity the author never expressed would be a false positive on
correct code. Where **no** linked view declares a lifecycle, warn — see (c).

**(c) Ordering inside the module.** `commandDef`s are built at ~line 447, well
before `linkedViews` is assembled at ~929. The check cannot run inline at
`mkDef`. It runs as a **second pass over the assembled structure**, once every
component is known — which is also the only point at which (b)'s union is
available.

**Severities.**

| Situation | Disposition |
|---|---|
| State name not in the union of linked lifecycle enums | **error** (fails the build) |
| Command has a from-set or target but no resolvable linked view | warn |
| Linked view resolves but declares no lifecycle field | warn |

The two warns are deliberate: hard-failing on an unresolvable link turns a
metadata gap into a deploy outage, and that population is broad. **Report the
warn count per plugin build**, so a plugin that is silently unvalidated is
visible rather than invisible — that population is also the one most likely to
be stale.

**Hand-authored definitions are validated, not exempted.**
`Platform_Admin_Structure.res` writes `allowedStates` as literals rather than
through the annotation. It is checked by the same rule; a literal is exactly as
capable of being wrong as an annotation.

**Open question this phase must answer, not inherit:** `checkRetiredValue`
*warns* when `@retired` names an undeclared state — a bug whose symptom is rows
leaking to callers who should not see them. This phase makes the milder bug (a
menu entry that never appears) a hard error. That asymmetry is indefensible on
its face; either `checkRetiredValue` is under-severe or this is over-severe.
Resolve it explicitly. The likely answer is that both belong in the same
findings list at the same severity, in which case promoting `checkRetiredValue`
is in scope for this phase and should be stated as such rather than discovered
later.

**Exit — met.** Implemented as `checkDeclaredTransitions` in `Plugin_Structure`,
a second pass over the assembled writable defs, with `lifecycleStatesFromStateSchema`
collecting each view's states as the view defs are built.

Verified two ways:

1. **Unit** — fixtures `PsShipmentsView` (a view declaring a lifecycle) and
   `PsDispatchShipment` (a command naming `Dispatchd`, which compiles because the
   PPX strips the attribute — the hole itself, reproduced). Three tests: the
   build throws, the message names the command, the state, the view and the known
   states, and a plugin whose views declare no lifecycle still builds.
2. **Against a real plugin** — a typo introduced into `online-shop-aggregates`
   fails `reventless/gwt`'s LocalHost integration, which cold-loads the real
   example plugins, with:

   ```
   Ordering: @transition names states that do not exist.
   Order.Ship: @transition names "Shippd", which none of its linked views
   declare — Orders know Placed, Shipped, Cancelled, Refunded.
   ```

   The second check matters because the first only proves the function works on
   fixtures the same commit wrote. Note that integration covers
   `online-shop-aggregates` only — the hybrid and dcb examples are validated at
   deploy or local-platform start, not by the test suite.

---

## §4 — Phase 3: the example sweep

15 attribute applications across the three shop examples, counted over
non-comment lines with `lib/` excluded:

| Example | Sites | Where |
|---|---|---|
| `online-shop-hybrid` | 10 | `ShipOrder` (from + target), `CancelOrder`, `Customer/Aggregate/Customer.res` ×2, `ArchiveProduct`, `UnarchiveProduct`, `DiscontinueProduct`, `ArchiveCategory`, `UnarchiveCategory` |
| `online-shop-aggregates` | 3 | all in `Order/Aggregate/Order.res` |
| `online-shop-dcb` | 2 | `ShipOrder`, `CancelOrder` |

Of these, exactly **one** is a `@targetState` — hybrid `ShipOrder.res:22`. Every
other state-changing command in all three examples declares where it may run
from and says nothing about where it lands.

The sweep does four things:

1. **Convert all 15 to `@transition`.**
2. **Add the missing target** to `CancelOrder` and to every Product/Category
   state-change command. Convert by reading each slice's `decide`, never
   mechanically: a one-sided conversion is a *claim that the command emits no
   state-moving event*, and a careless one silently drops the command out of
   every consumer that honours the distinction.
3. **Annotate the guard-only edit commands** with the one-sided form —
   `UpdateEmail`, `ChangeProductPrice`, `RenameCategory` and their siblings,
   none of which carries any annotation today.
4. **Fix the `OrderReopened` drift.** `ShipOrder_Behavior` gains the
   `OrderReopened` arm that clears its cancelled flag, and the `Orders` view
   projects a reopen back out of `Cancelled`. Today an order can be reopened and
   then never shipped, and renders `Cancelled` forever. **Preserve the pre-fix
   folds as a fixture before replacing them** — a bug-detector demonstrated only
   against a bug that no longer exists is not demonstrated.

**Also in this pass, because the sweep is already in these files:** the Order
slices' `{exists, shipped, cancelled}` boolean folds become a real variant. The
flag space representably contains `shipped && cancelled`, which the domain does
not have, and the house preference is a real variant over a bag of booleans.

**And the prose.** The examples are the documentation. With the old pair
removed, every doc comment, guide and scaffold naming `@allowedStates` is wrong
the moment §2 lands — and most occurrences of the string in these examples are
prose, not attribute applications. The sweep covers the `@lifecycle` / `@retired`
doc comments in `Products.res`, `Categories.res`, `Customers.res` and the slice
files, plus `Plugin.res`'s field docs. **This is part of this phase's exit, not a
follow-up.**

**Exit.** Every state-guarded command in all three examples carries a complete
declaration; §3 green with zero errors and a known warn count; GWTs green.

### What the sweep found that the plan did not predict

**Four Product edit commands do not guard, and must not be annotated as if they
did.** The plan named `ChangeProductPrice` as a guard-only command to annotate
`[Products.Listed]`. Reading its `decide` says otherwise: it checks only
`exists`, never the shelf status, and its slice does not consume the archive
events at all — so it accepts an edit on an archived *or* discontinued product.
`ChangeProductName`, `ChangeProductDescription` and `ChangeProductImage` are the
same. Annotating them `[Listed]` would declare a guard the write side does not
enforce, hiding a command from a menu where it in fact works — the stale-metadata
failure this workstream exists to end, freshly introduced by the sweep meant to
end it. **They are therefore left unannotated**, and the rule that produced that
answer is the rule to keep: the annotation describes what `decide` does, and
where `decide` guards nothing there is nothing to declare.

The Category equivalents (`RenameCategory`, `ChangeCategoryImage`) *do* refuse
with `CategoryAlreadyArchived`, consume both archive events, and are annotated
`[Categories.Listed]`. So the two halves of the same example teach opposite
things about editing a withdrawn row. That asymmetry is a **domain defect worth
its own decision** — either products should refuse edits when archived, as
categories do, or categories should stop refusing. It is deliberately *not*
fixed here: unlike the `OrderReopened` drift, no declaration is wrong and
nothing is internally inconsistent, so changing four behaviours would be a
domain change smuggled into an annotation sweep.

**The Customer aggregate splits cleanly**, and is the best illustration of the
one-sided form in the examples: `UpdateEmail`, `UpdateAddress` and
`SetAddressLocation` all return `Error(CustomerAlreadyDeactivated)` on a
deactivated customer, so each carries `@transition([Customers.Active])`. Its two
`@noApi` geocoding commands return `Ok([])` in *both* states — deliberately, so a
late-arriving geocode does not park a TODO row in Failed — which makes them legal
everywhere, and a from-set naming every state says nothing. They stay
unannotated.

### The pre-fix folds, preserved

§4 replaces `ShipOrder_Behavior`'s fold, and the replacement is what makes the
reopen work. The pre-fix version is recorded here because a bug-detector built
later cannot be demonstrated against a bug that no longer exists:

```rescript
type state = {exists: bool, shipped: bool, cancelled: bool}

let initialState = {exists: false, shipped: false, cancelled: false}

let evolve = (state, event) =>
  switch event {
  | OrderPlaced(_) => {exists: true, shipped: false, cancelled: false}
  | OrderShipped => {...state, shipped: true}
  | OrderCancelled => {...state, cancelled: true}
  // and no OrderReopened arm — the slice did not consume the event at all
  }
```

Paired with the `Orders` view, which consumed `OrderPlaced | OrderShipped |
OrderCancelled` and nothing else, the effect was: an order could be reopened,
never shipped again, and rendered `Cancelled` for the rest of its life. Nothing
declared was wrong; the folds simply disagreed with each other.

**Verified as a detector, not asserted.** §4 adds a GWT — "reopened order can
ship again" — which passes against the fixed fold and **fails** against the fold
above (checked by restoring the old semantics and running it). That is the
property a generated-conformance effort needs from this fixture.

---

## §5 — Phase 4: topology lint (the deploy-gate half)

Beyond name validity, which §3 settles. This phase asks whether the declared
graph makes sense:

- states no command can leave, and dead ends not marked `@retired`
- states nothing can reach
- **event-consumption completeness** — a warning when a slice folds a
  lifecycle-moving event that its sibling slices and the view ignore. This is
  the generalisation of §4's `OrderReopened` fix, and it is a check §3
  structurally cannot make: §3 validates *names against an enum*, while this
  asks whether *the folds agree with each other*.

Sequenced after §4 on purpose: run against a partially-annotated example it
would cry wolf on every entity.

**BUILT 2026-08-16, and one of its two rules was removed on contact with the
examples.**

**Unreachable states — kept.** A state in the enum that no command declares a
transition into, other than the first (where rows begin), is reported.
`lifecycleTopologyFindings` is pure and returns its findings; the reporting
wrapper logs them.

**Dead ends — written, run, removed.** The rule as planned was "a state nothing
can leave, and not marked `@retired`". It is wrong twice:

- It fires on correct models. `Shipped` and `Refunded` are terminal in the
  aggregates shop, as terminal states are in most lifecycles, and there is
  nothing to fix about either. Both were reported when the rule first ran.
- **Its suggested fix is harmful.** `@retired` does not mean "terminal" — it
  means *withdrawn from ordinary reads*. Marking a shipped order retired to
  silence a lint would hide every shipped order from every caller who cannot
  widen their read. An ending and a withdrawal are different facts, and nothing
  in the vocabulary distinguishes an intentional terminal from an accidental
  one, so the check cannot tell them apart and should not pretend to.

The rule is gone, with the reasoning recorded at the site so it is not
reintroduced. If terminal-state modelling is worth checking, it needs a way to
*declare* an ending first — which is a vocabulary question, not a lint one.

**Reported, not raised** — unlike §3. A state name that does not exist is
unambiguously a mistake; an unreachable state may be reached by a route this
metadata cannot see (an automation, an external system). Failing a deploy on
that would be the wrong trade, and a smell that stops a deploy gets silenced
rather than fixed.

**Not built: event-consumption completeness.** The §1.6 generalisation — warning
when a slice folds a lifecycle-moving event its siblings and the view ignore —
is still open. It is a different shape of question from either rule here: it
compares *folds against each other* rather than declarations against an enum,
and it wants the consumed-event sets that `writableDef` already carries.

**Exit.** Clean on all three examples — reached by deleting the rule that was
wrong rather than by suppressing what it found. Four unit tests over the pure
finding function.

---

## §6 — Risks

- **R1 — the arrow parse is the only novel code, and it fails silently.** A
  mis-read left operand yields an empty from-set, which validates fine and
  guards nothing. Mitigation: §2 pins both AST shapes in tests *before* the
  lowering is written, and §3 makes an empty from-set on a command that declares
  an arrow a finding in its own right.
- **R2 — §2 is breaking for any plugin outside this repo.** Nothing can stay
  unconverted and still build. That is intended and is why the removal is loud
  rather than silent, but it means §2 and §4 must land in one release.
- **R3 — validation is only as good as view linking.** Commands with no
  resolvable link fall through to a warning, and that population is the one most
  likely to be stale. Mitigation: the per-build warn count in §3.
- **R4 — the sweep is a teaching-surface change.** The examples teach the old
  pair in prose in more places than they use it in code. Mitigation: the prose
  sweep is inside §4's exit.
- **R5 — a careless one-sided conversion is invisible here.** It produces a
  command that declares it does not move rows while its `decide` emits a
  state-moving event. Nothing in this repo catches it; §3 checks names, not
  behaviour, and §5 checks topology, not agreement between a declaration and a
  fold. Mitigation: §4's rule that conversions are made by reading `decide`, and
  §4's preserved pre-fix fixture, which is exactly this failure captured for
  whoever builds the behavioural check.

---

## §7 — Interference

- **`order-line-items-and-totals.md` claims the same ordering slice.** It
  rewrites `OrderPlaced` to carry line items with quantity and a total; §4
  rewrites that slice's folds into a variant and adds the `OrderReopened` arm.
  **This plan goes first** — it is a single annotation pass, while line-items is
  a long capability change (a nested record walk through `@ref`, the three DCB
  tag walks, and SDL/JSON-Schema derivation) that would leave the sweep rebasing
  onto a moving slice. Line-items then lands on a settled fold.
- **`backlog/command-applicability-when-retired.md`** is already deferred behind
  `retired-as-a-lifecycle-state.md` on the argument that where retirement *is*
  the lifecycle, a from-set on the command suffices. §4's guard-only sweep is
  that argument carried out. What survives in the backlog is its genuinely
  orthogonal case: a row that is `Placed | Shipped | Cancelled` *and* separately
  archived, where applicability depends on two axes and one from-set cannot
  express it.
- **`domain-trait-extraction-online-shop-hybrid.md`** edits the same example.
  §4 is a single-pass sweep over command declarations and three behavior folds;
  it should land between that plan's waves, not inside one.

---

## §8 — Deferred

- **Generated lifecycle deciders.** Declared per-state outcomes
  (`Idempotent` / `Refuse(error)`) with the fold derived once from the view's
  projection — the only option that *removes* the duplication rather than
  checking it, and the riskiest (projection coupling, outcome vocabulary,
  redelivery semantics). It also contradicts the "each slice folds only what it
  needs" principle that DCB rests on. Its own plan, once §3 and §5 have run long
  enough to say whether checking the duplication is already cheap enough to live
  with.
- **Superstates**, per Non-goals. Revisit when a real domain repeats a from-set
  across many commands.
- **Parallel lifecycle axes.** Two axes on one entity (shelf status × stock
  status) is already representable as two enum fields; what is missing is only
  `@lifecycle` being singular. A metadata question, not a modelling one.
