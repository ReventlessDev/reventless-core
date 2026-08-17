# Defaulting a command's lifecycle guard — can `@transition([X.Active])` be dropped?

> **Superseded by
> [`lifecycle-model-from-gwt-corpus.md`](../lifecycle-model-from-gwt-corpus.md).**
> The four options below all answer *"how short can the claim be?"*. The
> follow-up analysis found that the claim need not be authored at all: the GWT
> corpus already contains the lifecycle machine, and reading it off scenarios
> derives from `decide`'s observed behaviour rather than from the read model's
> `@retired`. Two things here still stand and are cited by the successor — the
> measurement of the redundancy in §2, and the argument in §3 against deriving a
> claim about `decide` from a read-model annotation. §6's closing note (a GWT
> helper is worth more than items 1–4) is what the successor builds out.

**Question asked:** the hybrid ordering plugin's `Customer` aggregate carries
`@transition([Customers.Active])` on nearly every command. Each one says the
same two things — *legal only on an active customer, and it moves nothing*. Can
the framework infer that instead? Three candidate answers were put forward:

- **(A)** drop the annotations entirely and default to *commands are not allowed
  in retired lifecycle states*;
- **(B)** declare the default once per spec file, annotating only the exceptions;
- **(C)** pair `Customer` with `Customers` by name heuristic or a file
  annotation, so the command spec knows whose lifecycle to guard against.

**Verdict, up front.**

| | Feasible? | Recommended? |
|---|---|---|
| **(C)** pair the two specs | **Already done** — no new mechanism needed | n/a, dissolve the question |
| **(A)** implicit "not in a retired state" default | Yes, fully computable at plugin-structure assembly | **No — as a silent default.** It is wrong for 4 of the 9 guard-only annotations in the shipped examples, and wrong in the invisible direction. **Yes as a lint.** |
| **(B)** spec-level default + per-command override | Yes, exact precedent exists (`@@reventless.authorize`) | **Yes, but the win is smaller than it looks** — net −2 lines in the motivating file, and **zero** for every DCB slice |
| **(D)** *new* — a `NotRetired` shorthand as a `@transition` payload | Yes, smallest change of the four | **Yes — best return per unit of risk**, and composes with (B) |

The rest of this document is the evidence for those four rows.

---

## 1. What exists today

`@transition` is a per-variant PPX attribute
([TransitionAnnotation.ml](../../../packages/reventless-ppx/src/ppx/TransitionAnnotation.ml)),
in two forms:

```rescript
| @transition(([Orders.Placed]) => Orders.Shipped) ShipOrder(…)   // moves the row
| @transition([Customers.Active]) UpdateEmail(…)                  // guards, moves nothing
```

It lowers to two sury-metadata bindings on the command schema —
`markAllowedStates` / `markTargetState`
([Api.res:30](../../../reventless/infra/src/components/Api.res#L30)) — which
[Plugin_Structure.res:690](../../../reventless/core/src/plugin/component/Plugin_Structure.res#L690)
reads back per variant into `commandDef.allowedStates` / `.targetState`.

Three facts about that pipeline decide everything below.

**1a. It is presentation-only.** Nothing enforces `allowedStates` server-side.
The one consumer of record is
[AutoTypes.visibleByLifecycle](../../../../reventless-ui/reventless/ui/src/auto/AutoTypes.res#L318)
in `reventless-ui`, which filters a per-row command menu; the refusal itself
stays in `decide`. The annotation's whole job is to stop a menu offering what the
write side would reject.

**1b. The claim's ground truth is `decide`, not the view.** A from-set is a
statement *about the write side's behaviour*, written in the *read side's*
vocabulary. That asymmetry is the crux of option (A).

**1c. The lifecycle owner is already resolved.** For an aggregate,
`linkedViews = linkedSvsFor(produced) ++ linkedReadModelsFor(name)`
([Plugin_Structure.res:1202](../../../reventless/core/src/plugin/component/Plugin_Structure.res#L1202)),
where `linkedReadModelsFor` matches the aggregate's name against each read
model's declared `sourceNames`
([:859](../../../reventless/core/src/plugin/component/Plugin_Structure.res#L859)).
`Customers_Projections.res` declares `Mapping.Make(Customer, Customers, …)`, so
`Customer.linkedViews == ["Customers"]` falls out with no heuristic at all. The
same function already collects `lifecycleStatesByView`
([:1065](../../../reventless/core/src/plugin/component/Plugin_Structure.res#L1065))
and `retiredValues` per view
([:1109](../../../reventless/core/src/plugin/component/Plugin_Structure.res#L1109)).

**Consequence for (C): there is nothing to build.** Every input a default rule
would need — the aggregate, its view, the view's lifecycle states, and which of
them are retired — is already in hand inside one function,
`Plugin_Structure.buildStructure`. A name heuristic (`Customer` ↔ `Customers`)
would be a *weaker* signal than the declaration already present, and a new file
annotation would restate it. Neither should be built.

The only residual is disambiguation when **more than one** linked view declares a
lifecycle. That case does not occur in any shipped example, and the existing
name-validation check already handles it by taking the union
([:239](../../../reventless/core/src/plugin/component/Plugin_Structure.res#L239)).
If a default rule ever needs a single owner, add `@@reventless.lifecycleOf(Customers)`
as a *tiebreak only* — not as the general mechanism.

---

## 2. The redundancy, measured

Guard-only (`@transition([…])`, no arrow) applications across all three shop
examples, comments excluded:

| Sites | Annotation | Entity's retired states | Equals "all non-retired"? |
|---|---|---|---|
| 3 | `@transition([Customers.Active])` | `Deactivated` | **yes** |
| 2 | `@transition([Categories.Listed])` | `Archived` | **yes** |
| 4 | `@transition([Products.Listed, Products.Archived])` | `Archived`, `Discontinued` | **no** |

Nine sites total. Arrow-form applications (7 more) are unaffected by any proposal
here — they carry a target and are irreducible.

So the redundancy is real but small, and **it is not uniform**. Products
deliberately allow editing a *retired* row:
[ChangeProductPrice.res:18-27](../../../examples/online-shop-hybrid/catalog/src/Product/StateChangeSlice/ChangeProductPrice.res#L18-L27)
— "repricing is legal on a listed product and on an archived one — a product
pulled for a season is coming back, and its price should be right when it does."
`Products.shelfStatus` marks **both** `Archived` and `Discontinued` `@retired`
([Products.res:29-33](../../../examples/online-shop-hybrid/catalog/src/Product/StateViewSliceStream/Products.res#L29-L33)).

---

## 3. Option (A) — implicit "not allowed in retired states"

### It is mechanically easy

Inside `buildStructure`, for a command with no declared `allowedStates`, set
`allowedStates = lifecycleStatesByView[view] \ retiredValues[view]`. All inputs
are local; the wire shape is unchanged (`Some([…])`, exactly what an authored
annotation produces); **no consumer changes at all**. Roughly a 15-line change.

### It is wrong for 4 of the 9 sites

Applied to the shipped examples, the default reproduces the Customer and Category
annotations exactly (5 sites) and **contradicts** all four Product ones — it would
compute `[Listed]` where the domain says `[Listed, Archived]`. Those four commands
would silently vanish from an archived product's menu while
`ChangeProductPrice`'s `decide` went on accepting them.

The authors would keep the explicit `@transition` there, so the *code* stays
correct. The point is what the default is: **a narrowing default whose failure
mode is a missing button**. Nobody files a bug about a command they were never
offered, and it is exactly the stale-metadata failure the whole `@transition`
workstream exists to end.

### The deeper objection: it derives from the wrong source

`commandDef.requiredAccess` is derived, and its doc comment states why that is
safe: *"Derived rather than authored, so it cannot drift from the rule it
describes"*
([Plugin.res:207](../../../reventless/spec/src/components/Plugin.res#L207)). That
holds because it is derived from `commandAuthorization` — **the very rule the
server enforces**.

A retirement-based lifecycle default does not have that property. It derives a
claim about `decide` from an annotation on a *read model*. The two are written by
hand in different files and nothing keeps them in step, so the derived value can
be false on arrival — as it is for Products. Deriving from a proxy is not the
same kind of act as deriving from the source, and the existing precedent does not
license it.

### Two smaller costs worth naming

- **`allowedStates: None` currently means something.**
  [Plugin.res:173-190](../../../reventless/spec/src/components/Plugin.res#L173-L190)
  documents `None` (with `targetState: None`) as "simply an unannotated command",
  and the guard-only form as a *positive claim*. Auto-filling erases the
  distinction on the wire; a consumer can no longer tell an author's claim from
  the platform's guess.
- **The state-machine diagram would explode.**
  [StateMachineDiagram.res:47](../../../../reventless-ui/reventless/ui/src/components/StateMachineView/StateMachineDiagram.res#L47)
  draws `allowedStates: None` commands *outside* the state graph. Auto-filling
  attaches every unannotated instance command to every non-retired state node.

Both are answerable with the repo's existing idiom — a provenance rung, as
`labelFieldSource` and `idFieldSource` already do
([:1103](../../../reventless/core/src/plugin/component/Plugin_Structure.res#L1103)):
publish `allowedStatesSource: "declared" | "default"` so a consumer can rank the
claim. That is the right shape *if* (A) is ever built; it does not fix the
correctness objection above.

### Verdict on (A)

**Do not ship it as a silent default. Ship the same computation as a lint.** At
assembly time, for every Instance-level, API-exposed command with no
`@transition` whose linked view declares retired states, emit:

> `Ordering/Customer.SetLocation`: no `@transition`, but `Customers` declares
> retired state(s) `Deactivated`. Declare the from-set, or `@transition(Any)` to
> state that the command is legal everywhere.

Warning, not error — same severity split `checkDeclaredTransitions` already uses
([:208-214](../../../reventless/core/src/plugin/component/Plugin_Structure.res#L208-L214)).
This gets the user's actual goal (no command silently offered on a withdrawn row)
without the framework inventing a claim on the author's behalf.

---

## 4. Option (B) — a spec-level default

### The precedent is exact

[AuthorizationInjection.ml](../../../packages/reventless-ppx/src/ppx/AuthorizationInjection.ml)
already implements this shape: a file-level `@@reventless.authorize(<rule>)`
overrides the framework default, and a per-constructor `@authorize(rule)`
overrides the file. The parallel writes itself:

```rescript
@@reventless.spec
@@reventless.transition([Customers.Active])   // default for this spec's commands

@schema
type command =
  | Register({email: string, address: string})                        // exempt: creation
  | UpdateEmail({email: string})                                      // inherits [Active]
  | UpdateAddress({address: string})                                  // inherits [Active]
  | SetAddressLocation({address: string, location: GeoPoint.t})       // inherits [Active]
  | @noApi SetLocation(…)                                             // exempt: not exposed
  | @noApi MarkAddressUnresolvable(…)                                 // exempt: not exposed
  | @transition(([Customers.Active]) => Customers.Deactivated) Deactivate
  | @transition(([Customers.Deactivated]) => Customers.Active) Reactivate
```

### Where the work goes

Split it the way the codebase already splits syntax from semantics. The PPX
cannot decide exemptions — `commandLevelAndId`
([:597](../../../reventless/core/src/plugin/component/Plugin_Structure.res#L597))
and the `@noApi` resolution both live in `Plugin_Structure`, and duplicating
`isCreateCommandName` into the PPX would give two places to disagree.

1. **PPX** — extract `@@reventless.transition(…)`, reusing
   `TransitionAnnotation.states_of_expression` unchanged, and lower it as a *new*
   schema-level key: `markDefaultAllowedStates(commandSchema, [|"Active"|])`.
   Strip it, exactly as `strip_file_authorize_attrs` does.
2. **`Plugin_Structure.mkDef`** — after reading the per-variant `allowedStates`,
   fall back to the default when **all** of: no explicit entry, `level == Instance`,
   and `apiExposed`. All three are already computed in that function.
3. **Provenance** — publish `allowedStatesSource` as above, so the diagram and any
   future consumer can distinguish an inherited default from a declared claim.

The three exemptions are not conveniences; each is load-bearing:

- **Collection-level.** A creation command has no row to be in a state. The list
  view already only filters `instanceCmds`
  ([AutoListView.res:1491](../../../../reventless-ui/reventless/ui/src/auto/AutoListView.res#L1491)),
  so a default on `Register` would be inert in the menu and wrong in the diagram.
- **`@noApi`.** A non-exposed command has no generated menu entry, so a guard on
  it constrains nothing and only misstates the diagram. This exemption is what
  makes the mechanism pay for itself — see the count below.
- **Explicit `@transition` wins**, including a `@transition(Any)` opt-out, which
  this option needs adding regardless.

### Now count the actual win

Applied to `Customer.res` — 3 annotations removed, 1 spec-level line added, and
**0 opt-outs needed** because both always-legal commands are already `@noApi`:

> **net −2 lines** in the file that motivated the question.

Applied to the rest:

| File | Removed | Added | Net |
|---|---|---|---|
| `Customer.res` (aggregate, 8 commands) | 3 | 1 | **−2** |
| Category slices (`RenameCategory.res`, `ChangeCategoryImage.res`) | 1 each | 1 each | **0** |
| Product slices (4 files) | 1 each | 1 each | **0** |

**This is the finding that most changes the shape of the answer.** The hybrid
catalog is DCB: one `StateChangeSlice` per command, one command variant per file
([ChangeProductPrice.res](../../../examples/online-shop-hybrid/catalog/src/Product/StateChangeSlice/ChangeProductPrice.res)
declares a single-variant `type command`). A *file*-level default replaces one
annotation with one annotation there. **Option (B) helps aggregates and
multi-command slices only** — which is the motivating case, and nothing else.

### Verdict on (B)

Worth building, with clear eyes about scale: it is a readability win for
many-command aggregates, not a sweeping reduction. Its real value is that it puts
the fact in one place per entity, so adding a ninth customer command cannot
forget it.

---

## 5. Option (D) — a `NotRetired` shorthand (proposed)

Neither (A) nor (B) attacks the part that is genuinely brittle: the from-set
**restates the enum**, so adding `Customers.Suspended` silently leaves every
existing from-set narrower than the author intends, with no error anywhere.

Let `@transition` take a symbolic from-set beside a literal one:

```rescript
| @transition(NotRetired) UpdateEmail({email: string})
| @transition(Any) SetLocation(…)                          // the explicit opt-out
```

`NotRetired` resolves at assembly time to `lifecycleStates \ retiredValues` for
the linked view — the same computation as (A), but **written by the author**, so
it is a claim rather than an invention, and a Product command that disagrees
simply keeps listing its states.

What this buys over the alternatives:

- One token per command, no enum name repeated, no module reference to keep in
  sync.
- It stays correct when a state is added — the intent is expressed, not enumerated.
- It composes with (B): `@@reventless.transition(NotRetired)` is the whole of the
  user's wish, one line per spec, and it is honest.
- It is the smallest change of the four: the PPX needs one extra accepted payload
  shape, and the resolution already has all its inputs.

`Any` is needed by (A), (B) and (D) alike — today "legal everywhere" is expressed
by *silence*, and silence cannot be told from "nobody has looked at this yet".
That indistinguishability is the reason the lint in §3 has to be a warning rather
than an error.

---

## 6. Recommendation

Ranked, and each step is independently shippable:

1. **`@transition(Any)`** — an explicit "legal in every state". Cheapest, and a
   prerequisite for everything else. Turns silence into a statement.
2. **`@transition(NotRetired)`** (option D) — kills the enum restatement, keeps
   the claim the author's. This is the closest honest answer to "just drop the
   annotations".
3. **The §3 lint** — warn on an unannotated Instance-level exposed command whose
   view declares retired states. Delivers the *safety* half of option (A) without
   its silent-narrowing failure mode.
4. **`@@reventless.transition(…)`** (option B) — spec-level default, mirroring
   `@@reventless.authorize`. Do it for aggregates; expect no benefit for
   one-command DCB slices.
5. **Do not** ship option (A) as a silent computed default. Reconsider only if
   the Product asymmetry is resolved in the domain — and even then, the derivation
   still runs off the read model rather than off `decide`.
6. **Do nothing for (C)** — `linkedViews` already answers it.

### The complementary fix that matters more than any of the above

Every option here is about *how much you type*. The failure this metadata
actually produces is **drift**: a from-set that disagrees with `decide`. That is
what happened to the four Product commands, and it was caught by a human reading
`decide`, not by a tool.

The durable answer is a GWT helper that, for each declared from-set, drives the
slice's `decide` in every *other* declared state and asserts a refusal — turning
"the annotation describes what `decide` does" from a review convention into a
test. That is worth more than any of items 1–4, and none of them substitute for
it.

---

## 7. Prior art in this repo

- [`docs/plans/lifecycle-transition-annotation.md`](../../plans/lifecycle-transition-annotation.md)
  — built the annotation and its assembly-time name check. §4 records the Product
  finding cited above, and states the rule this analysis takes as its premise:
  *"a from-set is a claim about `decide`, so it is read off `decide` or it is not
  read at all."*
- [`docs/plans/backlog/command-applicability-when-retired.md`](../../plans/backlog/command-applicability-when-retired.md)
  — the `@whenRetired(Never | Also | Only)` draft, deferred. It explicitly names
  the gap this document addresses: *"that plan still owes the default answer for
  unannotated commands."* Its `Never`-as-default argument is option (A), and the
  Product counter-example above is the evidence it did not have.
- [`docs/plans/done/retired-as-a-lifecycle-state.md`](../../plans/done/retired-as-a-lifecycle-state.md)
  — why retirement became a lifecycle state rather than a second axis, which is
  what makes any of these defaults expressible at all.
