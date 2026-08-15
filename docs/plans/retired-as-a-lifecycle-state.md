# Plan: `@retired` on a state, not only on a boolean

**Status.** PLAN 2026-08-15. Extends a shipped annotation
(`retired-state-flag-annotation.md`) rather than adding a new one. Supersedes a
draft that proposed a second command annotation — see "What this replaces".

**Goal.** `@retired` currently names a **boolean** field. That forces a record
whose retirement is part of its lifecycle to carry the same fact twice: once as
the boolean the query layer filters on, and once as a value of the `@status` enum
that everything else — board columns, group sections, the lifecycle tracker, and
crucially `@allowedStates` — is expressed in terms of. Two sources of one truth,
free to drift, and no rule keeping them in step.

Let the annotation name a **state** instead:

```rescript
@schema
type accountStatus = Active | Deactivated

@schema
type state = {
  @id customerId: string,
  @displayName email: string,
  @retired(Deactivated) @status accountStatus: accountStatus,
}
```

One field. The query layer withholds rows whose status is `Deactivated`; the
badge, the sections and the tracker read the same field they already read; and
**`@allowedStates` becomes the command-applicability mechanism with no new
annotation at all**:

```rescript
| @allowedStates([Active]) UpdateEmail({email: string})
| @allowedStates([Active]) Deactivate
| @allowedStates([Deactivated]) Reactivate
```

That last line is the whole point. A consumer filtering a per-row command menu
against `allowedStates` already exists and already works; what was missing was
never a way to describe a command's stance on retirement, it was retirement being
expressible in the vocabulary the stance is already written in.

**What this replaces.** A draft plan added `@whenRetired(Never | Also | Only)` —
a third command annotation over a second axis. It is the right answer only where
retirement is genuinely orthogonal to a record's lifecycle (an order that is both
`Shipped` and archived), and the wrong answer everywhere else, because it
introduces a second vocabulary for a question `allowedStates` already answers.
Deferred to `Backlog/command-applicability-when-retired.md`, to be picked up if an
orthogonal case turns up in practice rather than in anticipation.

**Non-goal — dropping the boolean form.** It stays, and stays the right choice
for a record whose retirement genuinely is a flag rather than a state: a
`Products` view with an `archived` boolean and no lifecycle at all should not be
made to invent a two-valued enum. Both forms, one annotation, one wire key.

**Non-goal — enforcement of command applicability.** Unchanged from
`@allowedStates` today: it lets a consumer hide a command the write side would
refuse, and the refusal stays with `decide`. Nothing here adds a check to a
resolver.

---

## Shape

`x-reventless-retired` gains one optional member:

```
x-reventless-retired: {label?, showWhenFalse, value?}
```

- `value` absent ⇒ the boolean form, unchanged: the row is retired when the field
  is `true`.
- `value` present ⇒ the row is retired when the field equals that string.

`queryableDef` gains `retiredValue: option<string>` beside `retiredField`, so a
consumer reading the definition need not re-derive it from the schema.

**Payload is a constructor reference, not a string literal** —
`@retired(Deactivated)`, and `@retired({value: Deactivated, label: "Closed"})` in
the record form. This matches `@allowedStates`, whose payload is a list of
constructor references from which the PPX extracts leaf names. A string literal
would read the same and check nothing; a constructor reference at least states
the author's intent in the type's own vocabulary, and the misspelling that
survives it is caught by step 5.

**Annotated on the record field, not on the enum's constructor.** The
alternative — `type accountStatus = Active | @retired Deactivated` — reads
better, and was rejected because it puts the annotation somewhere the record
cannot see: the PPX would have to find which record field holds that type *and*
carries `@status`, across files, and say something useful when the answer is
"none" or "two". Keeping it on the field keeps the whole declaration in one place
and reuses the payload parser that is already there.

**The `@status` pairing is a requirement, not a convention.** A `value` form on a
field that is not the record's `@status` field is rejected (step 5). The point of
the form is that one field serves both purposes; a retirement state that no
consumer treats as the status would silently lose the command filtering that
motivates it.

---

## Steps

### 1. Spec — `retiredSpec`

```rescript
type retiredSpec = {field: string, label: string, showWhenFalse: bool, value: option<string>}
```

`None` ⇒ boolean form. Every existing construction site takes `value: None` and
is otherwise untouched.

### 2. PPX — accept the enum form

The bare and record payload forms both grow a constructor-reference slot:
`@retired(Deactivated)` and `@retired({value: Deactivated, label: …})`. The leaf
identifier is extracted the way `AllowedStatesAnnotation` extracts its list
items, and no witness binding is emitted — same conclusion, same reason.

**The type check inverts on the payload.** With no `value`, the field must be
`bool` / `option<bool>` exactly as today. With a `value`, the field must NOT be a
bool — it holds the enum the value belongs to — and the existing error message
("the annotation names a boolean") becomes wrong for that branch, so both
branches need their own.

The PPX cannot check that the value is a constructor of that enum: the type may
be declared in another file, and the witness trick is unavailable for the reason
recorded in `AllowedStatesAnnotation`. Step 5 does it where the schema is in
hand.

### 3. Core — carry the value through

- `retiredFieldFromStateSchema` gains a sibling yielding the value, or returns
  the pair; `Plugin_Structure` publishes `retiredValue` on `queryableDef` at both
  sites that already publish `retiredField`.
- `SuryToJsonSchema` emits `value` inside `x-reventless-retired` when present,
  omitted when not — the same "omit rather than write empty" rule the `label`
  member already follows.

### 4. Resolvers and publishers — one predicate becomes two

Every place that today asks "is this field `true`?" asks instead "does this field
equal the retirement value?", with the boolean form as the `value: None` case.
The three resolver families and the three publishers named in
`retired-state-flag-annotation.md` are the full list of sites; none of them gains
a new decision, only a widened comparison.

Worth stating because it is the one step with a performance shape: an equality
predicate over an enum-valued attribute indexes exactly as a boolean one does, so
the `@index` guidance and its read-cost warning carry over unchanged.

### 5. Validation — at structure time, where the schema is in hand

A `value` that is not one of the field's declared enum values, or a `value` form
on a field that is not the record's `@status` field, is an error naming the
known values — the check the PPX cannot make, in the one place that can. This is
the compile-time-ish backstop for the constructor reference in step 2.

### 6. Docs

The state-annotation reference: both forms, when to reach for each, and the
`@allowedStates` pairing that is the reason the state form exists. An author
reaching for the boolean form on a record that has a lifecycle should be able to
read why the other one is usually what they want.

---

## Tests

- **PPX** — the bare and record enum forms parse; the boolean form is unchanged;
  a `value` on a bool field and a bare `@retired` on an enum field are each a
  compile error with the message for *that* branch.
- **Emission** — `value` present on the annotated property for the enum form,
  absent for the boolean form; `queryableDef.retiredValue` matches.
- **Validation** — an unknown value is reported with the known ones listed; a
  `value` form on a non-`@status` field is reported.
- **Resolvers** — the enum form withholds rows whose status equals the value and
  serves every other; an elevated caller passing `includeRetired` gets them; the
  boolean form behaves exactly as its existing tests assert.
- **Publishers** — a row whose status moves *to* the retirement value has its
  payload withheld from the channel, as the boolean form does when it flips true.

## Acceptance

- A record declaring `@retired(Deactivated) @status accountStatus` is withheld
  from ordinary reads while deactivated, and `@allowedStates([Deactivated])` on
  the way-back command is enough to make a generated menu offer it there and
  nowhere else — with no annotation beyond the two.
- The boolean form is untouched, asserted by its existing suite passing unchanged.
- A record with a `@status` field and no `@retired` anywhere behaves exactly as
  it does today.
