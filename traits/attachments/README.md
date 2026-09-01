# @reventlessdev/trait-attachments

A **domain trait**: an ordered set of stored files on an entity — attach, remove,
choose the primary, caption — as domain facts. The rules are a module the host calls;
the types are the host's own:

| Part | Where |
|---|---|
| The set's rules | `src/Attachments_Rules.res` (`empty`, `op`, `fact`, `decide`, `evolve`, `primaryOf`) |
| The host contract, as a type | `src/Attachments.res` (`module type Binding`) |
| The conformance suite | `src/Attachments_Conformance.res` (`Make(Binding).register()`) |
| Spec fragments for the graft | `spec-fragments/*.res.tpl` |

`Attachments_Rules` is compiled code a host imports at runtime, so a change to it is a
behavior change for every host: version it `fix:`/`feat:` accordingly. The fragments are
the declarative residue that cannot come from a module — variant constructors, their
annotations, the state fields — and are still pasted and edited by hand.

Storage is the platform's (`UploadableImage.t` names the store; mint, presign and
pending-expiry are shipped). This package owns the rules of the *set*:

- **Attach and remove are idempotent** — a ref already in the set, or already out
  of it, appends nothing; a removed ref can come back.
- **The primary is one of the set.** Until one is chosen the first attached stands
  in; choosing the current primary appends nothing; removing the chosen one lets
  the first remaining stand in again.
- **A caption belongs to a member** — refused for a ref that is not attached,
  a no-op when repeated.
- **The read model carries the primary as one string** beside the set, so a card
  or a gallery tile has an image to draw without reading the set.

Unlike the geocoding trait this one writes nothing back into its host: the graft
*is* a StateChangeSlice of the host, so the contract is over that slice.

## Grafting a host

1. Paste the `spec-fragments/` into a `StateChangeSlice/<Entity>Images.res` pair and the
   view's projection, replacing `{{Entity}}`, `{{entity}}`, `{{entityId}}`,
   `{{file}}` (`productImage` — the field is named for its store), `{{Created}}`
   and `{{View}}`; add the host's own refusal to `decide`. The set's rules are not
   copied — the behavior fragment maps this host's constructors onto them.
2. Bind the host in a `_GWT.res` file and run the suite:

```rescript
module Binding = {
  type ref = string
  let refA = "/uploads/…/a.jpg"
  let refB = "/uploads/…/b.jpg"
  module Spec = ProductImages
  module Behavior = ProductImages_Behavior
  let created = [ProductImages.ProductAdded({productId: "p1"})]
  // … the remaining constructors, see `module type Binding`
}

TraitAttachments.Attachments_Conformance.Make(Binding).register()
```

The specimen hosts are `examples/online-shop-hybrid/catalog`'s `ProductImages` and
`CategoryImages`.
