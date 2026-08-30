# @reventlessdev/trait-file-attachment

A **domain trait**: an ordered set of stored files on an entity — attach, remove,
choose the primary, caption — as domain facts. It ships no runtime code:

| Part | Where |
|---|---|
| The host contract, as a type | `src/FileAttachment.res` (`module type Binding`) |
| The conformance suite | `src/FileAttachment_Conformance.res` (`Make(Binding).register()`) |
| Scaffold templates for the graft | `templates/*.res.tpl` |

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

1. Paste the `templates/` into a `StateChangeSlice/<Entity>Images.res` pair and the
   view's projection, replacing `{{Entity}}`, `{{entity}}`, `{{entityId}}`,
   `{{file}}` (`productImage` — the field is named for its store), `{{Created}}`
   and `{{View}}`; add the host's own refusal to `decide`.
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

TraitFileAttachment.FileAttachment_Conformance.Make(Binding).register()
```

The specimen hosts are `examples/online-shop-hybrid/catalog`'s `ProductImages` and
`CategoryImages`.
