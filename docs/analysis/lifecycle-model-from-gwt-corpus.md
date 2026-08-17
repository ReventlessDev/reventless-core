# The lifecycle state machine belongs to the GWT corpus, not to an annotation

**Status:** Analysis / proposal (no code changed by this document)
**Date:** 2026-08-17
**Author:** Martin Lorenz (with Claude)

**Supersedes:** [`rejected/command-lifecycle-guard-defaults.md`](./rejected/command-lifecycle-guard-defaults.md),
whose question — *"can `@transition([Customers.Active])` be defaulted away?"* —
turns out to be a special case of the question this document answers.

**Scope:** where a command's lifecycle guard (`allowedStates`) and its target
state (`targetState`) should come from; why deriving them from the GWT corpus is
sound where deriving them from the read model's `@retired` is not; the one gap
that derivation opens and the gate that closes it; and what remains for a human
to write.

---

## 1. How we got here

The reasoning trail matters, because each step invalidated the previous step's
framing rather than refining it.

**Step 1 — the original question.** The `Customer` aggregate carries
`@transition([Customers.Active])` on three commands. Each says the same two
things: *legal only on an active customer, and it moves nothing*. Can the
framework infer that? The predecessor analysis worked through four candidate
mechanisms and recommended a symbolic `NotRetired` payload plus a spec-level
default.

**Step 2 — the corpus said the objection was overstated.** That analysis rejected
a silent default because it "is wrong for 4 of the 9 guard-only annotations" —
the `ChangeProduct*` commands, which deliberately stay legal on an archived
product. But those four **carry an explicit annotation**, so a default would
never reach them. A sweep of all three shop examples found something stronger:

- `online-shop-aggregates` and `online-shop-dcb` declare no `@retired` state
  anywhere, so `NotRetired` resolves to the full state set — inert.
- In `online-shop-hybrid`, every command whose linked view has a lifecycle is
  already annotated. The rest are `Register` (Collection-level), the two `@noApi`
  geocoder commands, `RecordDemand`/`RevokeDemand` (no lifecycle view), and the
  four `SyncCatalogProduct` commands — whose view has no lifecycle enum at all
  (withdrawal is a row `Delete`).

**A `NotRetired` default would change nothing across the entire shipped corpus.**
The argument against it was never about correctness; it was about what a *silent*
default means for code not yet written.

**Step 3 — the target state is the irreducible half.** Under a `NotRetired`
default, `Deactivate`'s from-set `[Customers.Active]` is exactly the default. Its
*target* is not: nothing in `Customers.res` says which command lands in
`Deactivated`. So the annotation survives for its right half only, which argues
for a target-only form — and the PPX already parses the arrow's left side as a
pattern, so `_ => Customers.Deactivated` costs one extra case.

**Step 4 — could the target be computed from `decide` and `project`?** In
principle yes, and it would be the *good* kind of derivation: `requiredAccess` is
derived and safe precisely because it derives from `commandAuthorization` — the
rule the server enforces ([Plugin.res](../../reventless/spec/src/components/Plugin.res)).
Deriving `targetState` from `decide` derives from the source too, not from a
proxy. But it is unreachable where the value is populated:
[`Plugin_Structure.res`](../../reventless/core/src/plugin/component/Plugin_Structure.res)
contains **zero references** to `decide`, `evolve`, or `project`. It builds
entirely from sury schema metadata. Statically you would need the ReScript AST;
dynamically you would need a *reachable* state, and the behavior file defeats a
synthetic probe on its first line:

```rescript
| (NotCreated, Deactivate) => Error(CustomerNotFound)
| (Active(s), UpdateEmail({email})) if email == s.email => Ok([])
```

A probe starting from `initialState` gets an error, not an event; and
default-valued synthetic payloads land on the idempotency guards and return
`Ok([])`, so the probe concludes "moves nothing" for every editing command. The
repo's own `Ok([])`-on-no-change convention is what breaks it.

**Step 5 — the place where reachable states already exist is the GWT corpus.** A
scenario supplies exactly what the machine cannot invent: a real prior state and
a real payload. And once the corpus is the oracle, the question stops being *"how
do we keep the annotation honest?"* and becomes *"what is the annotation still
for?"* — which is where this document starts.

---

## 2. The corpus already contains the machine

Not "could be made to" — does. Here is the whole of `Customer`'s lifecycle,
transcribed from scenarios that exist today in
[`Customer_GWT.res`](../../examples/online-shop-hybrid/ordering/tests/Customer/Aggregate/Customer_GWT.res).

| Command | `givenEvents` | from-state | outcome | what it contributes |
|---|---|---|---|---|
| `Register` | `[]` | *(no row)* | `thenEvent(Registered)` | creates ⇒ Collection-level |
| `Register` | `[Registered]` | `Active` | `thenError(CustomerAlreadyRegistered)` | refused in `Active` |
| `UpdateEmail` | `[]` | *(no row)* | `thenError(CustomerNotFound)` | needs a row ⇒ Instance-level |
| `UpdateEmail` | `[Registered]` | `Active` | `thenEvent(EmailUpdated)` | **allowed in `Active`**, no move |
| `UpdateEmail` | `[Registered]` *(same email)* | `Active` | `thenNoEvent` | accepted, no effect |
| `UpdateEmail` | `[Registered, Deactivated]` | `Deactivated` | `thenError(CustomerAlreadyDeactivated)` | **refused in `Deactivated`** |
| `Deactivate` | `[Registered]` | `Active` | `thenEvent(Deactivated)` | **`Active` → `Deactivated`** |
| `Deactivate` | `[Registered, Deactivated]` | `Deactivated` | `thenNoEvent` | accepted, no effect |

Read off the table:

- `UpdateEmail` → `allowedStates: ["Active"]`, `targetState: None`
- `Deactivate` → `allowedStates: ["Active"]`, `targetState: Some("Deactivated")`

And the hand-written annotations in
[`Customer.res`](../../examples/online-shop-hybrid/ordering/src/Customer/Aggregate/Customer.res):

```rescript
| @transition([Customers.Active]) UpdateEmail({email: string})
| @transition(([Customers.Active]) => Customers.Deactivated) Deactivate
```

**Identical.** The derivation reproduces what a human wrote, from scenarios
written for an unrelated purpose, with no annotation consulted.

### How a state gets its label

The `givenEvents` list is a list of events, not a state name. Labelling it means
folding it through `project` and reading the `@lifecycle` field:

```rescript
// Customers_Projections.res
| Deactivated => Update(id, state => {...state, accountStatus: Deactivated})
| Reactivated => Update(id, state => {...state, accountStatus: Active})
```

`[Registered, Deactivated]` folds to `accountStatus: Deactivated`; `[Registered]`
folds to `Active`; `[]` folds to *no row at all*, which is what makes `Register`
Collection-level and `UpdateEmail` Instance-level.

Two consequences worth stating explicitly:

1. **`project` is the labelling function**, so it must exist before the aggregate
   corpus can be labelled. In the generation pipeline of
   [`given-when-then-specifications.md`](./given-when-then-specifications.md)
   that is Stage C before the lifecycle model, not after.
2. **The Collection/Instance split comes out for free**, and it comes out
   *right*. Today it is a prefix guess over
   `["Add", "Create", "Register", "Open", "Initialize", "Submit", "Start", "Place"]`
   in `Plugin_Structure.commandLevelAndId`. A command called `Enroll` or
   `Provision` is misclassified; the corpus never is, because "succeeds from no
   row" is the actual definition.

---

## 3. The rule that makes the derivation correct

The obvious rule — *`allowedStates` = the states where the command did not
error* — is wrong, and the repo contains a live example of why.

```rescript
// Customer_Behavior.res
| (Active(_), Deactivate) => Ok([Customer.Deactivated])
// Already where the caller is asking it to be.
| (Active(_), Reactivate) => Ok([])
```

`Reactivate` is **accepted** on an active customer. It is annotated
`@transition(([Customers.Deactivated]) => Customers.Active)` — from-set
`[Deactivated]` only. So the annotation and `decide` already disagree in shipped
code. Harmlessly — the annotation hides a button that would be a no-op — but it
shows that the two predicates are genuinely different:

- `decide`'s `Ok([])` means **"do not fail here."**
- `allowedStates` means **"offer this here."**

Idempotency — the repo's own convention that a no-change command returns `Ok([])`
rather than an error — systematically widens the first beyond the second. A
derivation keyed on "did not error" would put a useless `Reactivate` button on
every active customer.

**The correct rule keys on effect, not acceptance**, and the corpus already
distinguishes the three outcomes:

| Scenario ending | Meaning | In `allowedStates`? | Edge? |
|---|---|---|---|
| `thenEvent(…)` | accepted, produced events | **yes** | if the lifecycle field moves |
| `thenNoEvent` | accepted, no effect | **no** | no |
| `thenError(…)` | refused | **no** | no |

Apply it to the table in §2 and `Deactivate` yields `["Active"]` — the
`thenNoEvent` scenario on a deactivated customer correctly excluded. That is why
the derived values match the authored ones exactly.

### The corpus also finds the gaps

Grepping the same file for command coverage:

```
5 whenCmd(SetLocation      2 whenCmd(Register
4 whenCmd(UpdateEmail      2 whenCmd(Deactivate
2 whenCmd(UpdateAddress    1 whenCmd(MarkAddressUnresolvable
2 whenCmd(SetAddressLocation
```

**`Reactivate` has zero scenarios** — yet it declares a lifecycle edge. Under the
recommendation below that is a reportable coverage gap:

> `Ordering/Customer.Reactivate`: declared edge `Deactivated → Active` has no GWT
> scenario. Add `givenEvents([Registered(…), Deactivated]) -> whenCmd(Reactivate)
> -> thenEvent(Reactivated)`, or drop the declaration.

That is a real finding in the shipped examples, produced by the mechanism rather
than by someone reading `decide`.

---

## 4. What the corpus replaces outright

**The multi-target question dissolves.** A command that lands in two states
depending on payload simply produces two observed edges. There is no wire shape
to design and no cross-product ambiguity — which there *would* be if
`targetState` became `array<string>` beside `allowedStates: array<string>`:
`[Placed, Approved] × [Shipped, PartiallyShipped]` reads as four edges, of which
at most two exist. The from/to pairing is a relation, not a pair of sets, and a
corpus yields the relation directly.

Worth noting for prioritisation: all ten arrow-form annotations in the three
examples have exactly one target. The cost being paid today is not a wrong
diagram but a silent one — an author with a branching command has no way to say
so, drops to the guard-only form, and the board loses the edge.

**The `NotRetired` / `Any` / spec-level-default design becomes unnecessary as a
source.** Every one of those was a shorter way to write a claim. When the claim
is read off scenarios, brevity of the claim stops being the problem.

---

## 5. The gap this opens — and the gate that closes it

Deriving the model from the corpus is only sound if the implementation cannot
exceed the corpus. In the generation pipeline it can, and this is the one genuinely
new risk.

Stage E's acceptance gate is *"every GWT scenario returns `Ok`"*. That is a
**lower bound, not an equality**. A generated `decide` satisfying every scenario
may also accept commands in states no scenario mentions. Concretely, with no
`Reactivate` scenario in the corpus, all three of these pass:

```rescript
| (Active(_), Reactivate) => Ok([])            // what the human wrote
| (Active(_), Reactivate) => Ok([Reactivated]) // spurious event, corpus-clean
| (Active(_), Reactivate) => Error(CustomerNotFound)
```

So the published model (corpus-derived) can be **narrower** than the shipped
implementation (corpus-accepted). That is drift again — same failure, new
location: no longer between annotation and implementation, but between
corpus-derived model and corpus-accepted implementation. Removing the annotation
does not remove it, because the annotation never caused it.

**The fix is to make the acceptance gate closed-world.** Require the generator to
emit an explicit refusal for every `(state, command)` cell the corpus does not
cover, rather than a permissive fall-through. Then implementation ≡ corpus
exactly, and the derived model is sound by construction.

This is also the answer to *"what if the GWT scenarios aren't there?"*:

| | Missing scenario ⇒ | Failure mode |
|---|---|---|
| **Open-world gate** | generator improvises the cell | unspecified behaviour ships silently |
| **Closed-world gate** | cell refuses | the feature is *absent*, visibly, at first use |

Fail-closed is the correct default for generated domain logic, and it costs one
rule in the stub generator. It is what makes "provide only the spec and the
scenarios, and everything is fine" true rather than approximately true.

---

## 6. What the corpus still cannot give you

§5.3 of the GWT analysis names cross-entity invariants, side-effect contracts and
read-model query patterns. The `Customer` behaviour adds a sharper category —
**guards that compare a payload against current state**:

```rescript
// Stale: the slice is reporting on an address this customer has since moved off.
| (Active(s), SetLocation({resolvedFrom})) if resolvedFrom != s.address => Ok([])
| (Active(s), UpdateEmail({email})) if email == s.email => Ok([])
```

Expressing these by example needs at least two scenarios each, and the
generaliser must infer *"these two fields are compared"* rather than *"this
literal equals that literal"* — an underdetermined choice among many that fit.
The useful decomposition:

- **Lifecycle layer** — finite states, constructor-level edges. Learnable from
  traces. This is the whole of `@transition`, and it is tractable.
- **Data layer** — guards over payload values, invariants across fields. Inductive
  synthesis, underdetermined, and where a scenario corpus stops being smaller than
  the implementation it replaces.

The generation pipeline is honest about this: Stage B is an LLM proposing a body
and iterating against the corpus as fitness function, not a compiler. Many
implementations satisfy the same corpus — `Deactivated({email, address, location,
locationResolvedFrom})` carries the profile so `Reactivate` can restore it, and
only some representations leave the *next* scenario expressible.

---

## 7. Recommendation

### 7.1 The shape

**The GWT corpus is the source of the lifecycle model. The annotation is a
coverage obligation, not a claim to be checked.**

1. **Derive the model from the corpus.** Harvest observed
   `(fromState, command, outcome, toState)` from the PPX's `.gwt.json` sidecars
   ([SidecarEmit.ml](../../packages/reventless-ppx/src/ppx/SidecarEmit.ml)),
   labelling states by folding a per-event lifecycle map read off the projection
   corpus. Apply the effect-not-acceptance rule of §3. Publish `allowedStates` /
   `targetState` / Collection-vs-Instance from the result.

   The sidecar is a **compile-time** artifact, which matters more than the
   convenience: it means the harvest is a build step like every other input to
   `buildStructure`, not a consumer of test *execution*. Making deploy-time
   metadata depend on a test run would be the wrong shape — a deleted test file
   would silently change a production command menu.

2. **Close the world.** Every `(state, command)` cell absent from the corpus
   refuses. Without this, everything above is unsound.

3. **Keep `@transition` — with a new job.** It declares the *intended* edge set,
   and the harvester reports three verdicts per declared edge:

   | Verdict | Meaning | Severity |
   |---|---|---|
   | **confirmed** | a scenario exhibits the edge | — |
   | **contradicted** | scenarios exhibit a different edge | **error** |
   | **unverified** | no scenario covers it | **warning**, with a count |

   The same severity split [`checkDeclaredTransitions`](../../reventless/core/src/plugin/component/Plugin_Structure.res)
   already uses. `Reactivate` above is a live *unverified*.

4. **Let the annotation generate scenario obligations.** This is where the
   earlier `NotRetired` idea earns its place after all — not as a from-set
   shorthand, but as a *test generator*: `@transition(NotRetired)` expands to a
   refusal obligation for every retired state, so adding `Suspended` to the enum
   immediately produces a new unmet obligation rather than a silently narrower
   menu.

### 7.2 What this means for the four earlier options

| Option | Verdict now |
|---|---|
| (A) silent `NotRetired` default | **Unnecessary.** The corpus answers it, and answers it from `decide`'s behaviour rather than the read model's `@retired`. |
| (B) spec-level `@@reventless.transition` | **Unnecessary as a default.** Possibly useful as a *bulk obligation* declaration. |
| (C) pair the specs by name | **Still dissolved** — `linkedViews` already answers it, and the corpus needs the link only for labelling. |
| (D) `NotRetired` payload | **Repurposed** — from from-set shorthand to obligation generator (7.1 §4). |
| `targetState` as an array | **Dropped.** The corpus yields a relation; parallel arrays would read as a cross product. |

### 7.3 Sequencing

Each step is independently useful and none blocks on the generation pipeline
landing:

1. **Harvest from the sidecars that already exist.** No new plumbing: the PPX
   emits `<Stem>.gwt.json` beside every `@@reventless.gwt` file under
   `REVENTLESS_EMIT_SIDECAR=1`, and the three outcomes are already
   distinguishable — `then: [{kind:"event"}]`, `then: []` (that is
   `thenNoEvent`), `then: [{kind:"error"}]`. Exactly the discriminator §3 needs.
   The sidecars are gitignored build artifacts, so the harvest drives its own
   build with the flag set rather than relying on one having happened.
2. **Build the harvester and the three verdicts.** Report only; change no
   published metadata. This alone catches the `Reactivate` gap and any
   contradiction, and is worth shipping on its own.
3. **Switch `allowedStates` / `targetState` to corpus-derived** where a corpus
   exists, keeping the annotation as the obligation set. Publish
   `allowedStatesSource` so a consumer can rank a derived edge against a declared
   one — the state-machine diagram in `reventless-ui` draws unannotated commands
   outside the graph today and needs the distinction.
4. **Add the closed-world gate** to the generation pipeline's stub stage, before
   any generated `decide` ships.

### 7.4 What stays hand-written

Generated behaviour should follow the precedent already set by
`generate-plugin`: `src/Plugin.res` is generated, **committed to git**, and
compiled directly by CI. Generate `Customer_Behavior.res` the same way —
generated once, owned thereafter, regenerable for new constructors without
overwriting a developer's `decide`. Stage A is already specified as idempotent in
exactly this sense.

And the spec file stays authored regardless. It is where the *why* lives — the
three-state location design, the `resolvedFrom` staleness rule, why `Deactivated`
carries the profile. No scenario carries a rationale, and generated code carries
no comments.

---

## 8. Prior art

- [`given-when-then-specifications.md`](./given-when-then-specifications.md) §5 —
  the generation pipeline this document extends. §5.1 already lists `decide` as
  "derivable but lossy" and §5.2 concedes that many state shapes satisfy one
  corpus; §5.6 adds the closed-world gate and the corpus-derived lifecycle model.
- [`rejected/command-lifecycle-guard-defaults.md`](./rejected/command-lifecycle-guard-defaults.md) —
  rejected. Its measurement of the redundancy (§2) and its argument against
  deriving a claim about `decide` from a read-model annotation (§3) both stand;
  its four options are answered by §7.2 above. Its closing note — that a GWT
  helper checking from-sets against `decide` "is worth more than any of items
  1–4" — is what this document builds out.
- [`lifecycle-transition-annotation.md`](../plans/lifecycle-transition-annotation.md) —
  built the annotation and its assembly-time name check, and states the premise
  this analysis takes as given: *"a from-set is a claim about `decide`, so it is
  read off `decide` or it is not read at all."*
- [`command-applicability-when-retired.md`](../plans/backlog/command-applicability-when-retired.md) —
  the deferred `@whenRetired` draft, which named the gap ("that plan still owes
  the default answer for unannotated commands"). The answer is: the corpus.
- [`retired-as-a-lifecycle-state.md`](../plans/done/retired-as-a-lifecycle-state.md) —
  why retirement is a lifecycle state rather than a second axis, which is what
  makes a single derived state label possible at all.
