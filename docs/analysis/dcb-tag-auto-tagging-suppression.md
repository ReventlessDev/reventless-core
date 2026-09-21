# DCB Tag Auto-Tagging Suppression

> **Status: ✅ Resolved — Option B shipped, as `@noDcbTag` (not `@dcb.skip`).** The attribute is
> live in `ReferenceInference.ml`, which routes a field carrying it to
> `Reference.toWithoutDcbTag`, and the VS Code extension offers it as a code action on a
> `consumedEvent` arm field: *"Suppress DCB tag (@noDcbTag) — this id is payload, not a boundary
> key."* Everything below is kept as the reasoning that led there; the recommendation section
> still names the attribute `@dcb.skip`, which never existed under that spelling.
>
> 🚨 **Option E (the `*Ref` suffix) is superseded, and does not compose with `@ref`.** See the
> note under that option. Read this document for *why* suppression is explicit, not as a menu of
> live choices.

**Context**: `@@reventless.dcbTags` (and auto-application in `*Slice` folders via Phase 8) injects
`@s.matches(Reventless.DcbTag.string)` on every `*Id: string` field in `@schema` variant types.
This is convenient for the common case but creates false positives when a slice command carries
identifier fields that are **not** DCB query keys.

## The Problem

`PlaceOrder.command` in the hybrid ordering example:

```rescript
@schema
type command =
  | PlaceOrder({
      orderId: string,    // ← IS a DCB query key (partition tag for Order)
      customerId: string, // ← is NOT a DCB query key (payload field, no Customer events in this log)
      productId: array<string>, // ← IS a DCB query key (cross-entity query for CatalogProduct)
    })
```

After PPX transformation:
```js
let commandSchema = S.schema(s => ({
  TAG: "PlaceOrder",
  orderId: s.m(DcbTag.string),      // correct
  customerId: s.m(DcbTag.string),   // wrong — creates spurious query clause
  productId: s.m(S.array(DcbTag.string)), // correct
}));
```

`buildQueryFromCommand` (cross-entity mode, triggered by the tagged array) expands each tag to its
own OR clause. The `customerId=cust-1` clause then matches `OrderPlaced` events from **all** orders
placed by `cust-1`, causing the decision model to see `state.exists = true` for a brand-new order.

The PPX has no way to distinguish "DCB entity ID used for querying" from "identifier reference
stored as payload". Both match the naming convention `*Id: string`.

## Current Workaround

```rescript
customerId: @s.matches(S.string) string
```

`has_s_matches_attr` in `DcbTagInference.ml` already suppresses auto-injection when the type
already has `@s.matches`. Using `@s.matches(S.string)` exploits this gate to opt out. It works but
is not self-documenting — the reader can't tell whether the `S.string` is load-bearing or just a
suppression mechanism.

## Options

### Option A — Keep current opt-out via `@s.matches(S.string)` (status quo)

No PPX changes. Document the pattern in the app-developer guide.

**Pros**: Already implemented; no new attributes needed.
**Cons**: Obscure intent — looks like a redundant schema annotation rather than an intentional
opt-out. A reviewer unfamiliar with the gate would likely remove it.

---

### Option B — Dedicated `@dcb.skip` opt-out attribute

Add a new check in `DcbTagInference.transform_label_decl`:

```ocaml
let has_dcb_skip_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "dcb.skip"
  ) attrs

(* in transform_label_decl — add to guard: *)
&& not (has_dcb_skip_attr ld.pld_attributes)
```

Usage:

```rescript
customerId: @dcb.skip string
```

**Pros**: Intent is explicit; easy to grep for opt-outs; mirrors the existing `@s.matches` gating
but at the field declaration level (not the type expression).
**Cons**: New attribute to document; attribute goes on the field name, not the type (different
position from `@s.matches`). The PPX must check `ld.pld_attributes` rather than
`ld.pld_type.ptyp_attributes`.

---

### Option C — Opt-in only: explicit `@dcb.tag` replaces auto-inference

Remove the `*Id` name heuristic entirely. Only tag fields explicitly annotated:

```rescript
@schema
type command =
  | PlaceOrder({
      orderId: @dcb.tag string,
      customerId: string,           // not tagged — no annotation
      productId: array<@dcb.tag string>,
    })
```

**Pros**: Zero false positives; completely explicit; mirrors how sury-ppx works.
**Cons**: Loses the main ergonomic benefit of `@@reventless.dcbTags` — every tag field needs an
annotation. The convention-over-configuration appeal disappears. The simple case
`type command = AddProduct({productId: string, name: string})` now requires `@dcb.tag` on
`productId`.

---

### Option D — Smarter heuristic: only auto-tag in single-`*Id` variants

Auto-tag only when the variant has exactly one `*Id` field. If multiple `*Id` fields exist,
require explicit annotation on all of them.

```rescript
(* Single *Id field → auto-tagged *)
type command = AddProduct({productId: string, name: string})

(* Multiple *Id fields → ERROR or no-op, user must annotate explicitly *)
type command = PlaceOrder({orderId: string, customerId: string, productId: array<string>})
```

**Pros**: Eliminates ambiguity by refusing to guess when multiple candidates exist.
**Cons**: Requires counting `*Id` fields per variant at transform time, complicating the OCaml PPX.
The no-tagging-on-multiple behavior might be surprising. Cross-entity commands inherently have
multiple `*Id` fields (the partition tag + the foreign keys) so this option blocks the main
cross-entity use case without extra annotations.

---

### Option E — Suppress via naming: non-entity IDs use a different suffix convention

Adopt a convention: DCB query keys use `*Id` / `*Ids`; non-entity payload references use `*Code`,
`*Ref`, or a different plural — no PPX change required.

```rescript
type command =
  | PlaceOrder({
      orderId: string,          // DCB tag → tagged
      customerRef: string,      // not *Id → not tagged
      productId: array<string>, // DCB tag → tagged (array)
    })
```

**Pros**: No PPX change; natural naming also documents intent.
**Cons**: Requires renaming existing fields (`customerId` → `customerRef`); may conflict with
established domain vocabulary; the rename cascades to event types, read models, and tests.

> 🚨 **Superseded — do not adopt (2026-09-21).** Three reasons, the last of which did not exist
> when this was written:
>
> 1. **It suppresses by failing to match a rule, so it states nothing.** `isIdName` is
>    `endsWith("Id") || endsWith("Ids")`, and a `*Ref` name simply misses it. Nothing records
>    that the omission was deliberate, and renaming the field back to `customerId` later — an
>    innocent tidy-up — silently makes it a DCB key again. `@noDcbTag` survives a rename and greps.
> 2. **It costs the reference inference.** Auto UI infers a reference from a field name by
>    stripping `Id`/`Ids` (`AutoUI.stemFromKey`) whenever the author declared none, so a `*Ref`
>    field gets no picker in the generated UI — it gets a box someone types a raw id into.
> 3. **🚨 It does not compose with `@ref`.** `Reference.to_` sets the DCB tag metadata *itself*,
>    so `@ref("Customers") customerRef` is tagged after all — under the key `customerRef`, which
>    no `*Id`-named producer will match. The naming trick suppresses only the *inference*; an
>    explicit reference overrides it in the other direction. Getting "a reference that is not a
>    boundary key" therefore needs `@ref("Customers") @noDcbTag customerId`, where the annotation
>    does all the work and the suffix does none.
>
> **The convention is `*Id` in every case**, with `@noDcbTag` where the field is payload rather
> than a key. That is also what the framework's own specs do: `productId`, `productIds`,
> `categoryId`, `customerId`, `warehouseIds` — and no `*Ref`-suffixed reference field anywhere.

---

## Recommendation

*(Historical — `@dcb.skip` shipped as `@noDcbTag`; see the status note at the top.)*

**Option B** (`@dcb.skip`) for the short term — it makes suppression intent explicit with minimal
PPX complexity and is easy to grep. The PPX change is ~5 lines in `DcbTagInference.ml`.

If the convention proves noisy (many fields needing `@dcb.skip`), revisit **Option C** (explicit
`@dcb.tag`) as a breaking PPX change. Option C is the more principled design but trades
convenience for correctness.

~~**Option E** is worth considering alongside B as a complementary naming convention for
command payload fields that happen to be identifiers.~~ **Withdrawn** — see the note under
Option E.
