# Plan: `@whenRetired` — a command's stance on an orthogonally-withdrawn row

**Status.** BACKLOG 2026-08-15. Deferred in favour of
`retired-as-a-lifecycle-state.md`, which solves the motivating case without a new
annotation. Kept because it remains the answer to a narrower case that plan does
not reach. Pick it up when that case turns up in a real domain — not before.

**The case this is still for.** A record whose retirement is genuinely orthogonal
to its lifecycle: an order that is `Placed | Shipped | Cancelled` *and*
separately archived. There, retirement cannot be a value of the status enum
without multiplying the enum by two, and a command's applicability may depend on
both axes at once — "legal while Shipped, and only once archived" — which one
`@allowedStates` list cannot express.

**Why it was deferred.** The original motivation was a generated surface offering
commands the write side refuses on a withdrawn row. That framing took a second
axis as given. It is not: where retirement *is* the lifecycle, letting `@retired`
name a state of the `@status` enum makes `@allowedStates` — which already exists,
and which a per-row command menu is already filtered by — sufficient. Adding a
second vocabulary for a question the first already answers is the cost this
defers.

The rule for reviving it: an orthogonal flag in a real domain, not a hypothesis
about one. If the first candidate turns out to be a lifecycle wearing a boolean's
clothes, the answer is the other plan.

---

## Shape, as drafted

A per-variant command annotation beside `@allowedStates` and `@targetState`:

```rescript
| @whenRetired(Only) Reactivate
```

| value | offered on a live row | offered on a retired row |
| --- | --- | --- |
| `Never` (default) | yes | no |
| `Also` | yes | yes |
| `Only` | no | yes |

`Never` as the default is deliberate: retiring a row withdraws it from ordinary
use, so a command that still applies is the exception, and an exception is what
an annotation is for. The usual objection to a restrictive default — it changes
behaviour for the un-opted-in — does not apply, because the axis exists only
where a record declares `@retired`.

Emitted unconditionally on every command variant, so "absent" means exactly one
thing (a platform predating the field) rather than two. Meaningless on a
collection command, which has no row to be retired, and rejected there rather
than ignored.

Presentation only, exactly as `@allowedStates` is: it lets a consumer hide a
command the write side would refuse; the refusal stays with `decide`. That is
what keeps it small — no resolver, publisher or channel work.

## Sketch of the steps

1. `commandDef.whenRetired: option<string>` in the spec, beside `allowedStates`.
2. PPX: per-variant attribute mirroring `AllowedStatesAnnotation`, single
   constructor-reference payload, three accepted tokens, rejected on a collection
   command.
3. `ApiWhenRetiredHelpers` beside `ApiAllowedStatesHelpers`; `Plugin_Structure`
   fills the field at the two sites that fill `allowedStates`.
4. `whenRetired: String` on `Platform_CommandDef` in the admin SDL and encoder.
5. `Platform_Admin_Structure`'s hand-written `commandDef` literals gain the field.

## The consumer half

Filed separately, in the repo that owns the generated surfaces: a sibling of the
existing status filter — two axes, two questions — composed with it at each
per-row command site, with absent ⇒ offered so an older platform is unaffected
and an unknown token ⇒ offered so a newer one cannot take an affordance away.
