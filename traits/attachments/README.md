# @reventlessdev/trait-attachments

A **domain trait**: an ordered set of stored files on an entity — attach, remove,
choose the primary, caption — as domain facts. The rules are a module the host calls;
the types are the host's own:

| Part | Where |
|---|---|
| The set's rules | `src/Attachments_Rules.res` (`empty`, `op`, `fact`, `decide`, `evolve`, `primaryOf`) |
| The host contract, as a type | `src/Attachments.res` (`module type Binding`) |
| The conformance suite | `src/Attachments_Conformance.res` (`Make(Binding).register()`) |
| The emitter | `src/Attachments_Scaffold.res` (`emit(~config, ~into, ~tests)`) |

`Attachments_Rules` is compiled code a host imports at runtime, so a change to it is a
behavior change for every host: version it `fix:`/`feat:` accordingly.

The graft *is* a StateChangeSlice, so the emitter writes nearly all of it: the slice
spec, its behavior and the conformance binding, whole. Only the view's projection is
printed as a patch — the view already exists, and placing an arm in an ordered `switch`
is an AST operation a text splice gets silently wrong.

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

1. Run the emitter. Every `--key` is a field of its config, and it validates them, so
   run it once to be told what it wants:

```sh
pnpm exec graft-trait @reventlessdev/trait-attachments \
  --into src/Product --tests tests/Product \
  --entity Product --entityId productId --noun Image \
  --file productImage --created ProductAdded --view Products
```

   The field is named for the store it draws from, and `--noun` is what this host calls
   one attachment — it runs through every name the graft declares.

2. Fill the `TODO(graft)` markers. They are the host's own policy: the events its
   refusal turns on, the error it raises, and the `else if` in `decide` that raises it
   ahead of the set's rules. A graft with no extra refusal is a complete graft, so
   leaving them is legitimate.

3. Paste the projection patch, and run the emitted conformance binding — 14 assertions,
   over your constructors, not the trait's.

The specimen hosts are `examples/online-shop-hybrid/catalog`'s `ProductImages` and
`CategoryImages`.
