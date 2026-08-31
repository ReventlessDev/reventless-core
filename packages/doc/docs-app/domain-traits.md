# Domain Traits

A **domain trait** packages a competency that keeps reappearing across domains —
turning an address into a map point, keeping a set of images on a product — so a
new application can adopt it without re-deriving the rules that make it safe.

The shape of the deal is one sentence: **the rules are a module you call; the types
are yours.**

- **The rules are compiled once, in the trait.** The guards, the folds, the
  fallbacks — the handful of arms that are hard to get right and easy to get subtly
  wrong — live in a module your host imports and calls. Fixing one is a release of
  the trait, not an edit to every host that copied it.
- **The spec surface stays yours.** Variant constructors are closed and their names
  belong to your domain; the annotations the ppx and the plugin generator read are
  read off *your* source. That residue — twenty to forty declarative lines per host
  — is pasted from the trait's spec fragments and edited by hand.
- **What was already shared stays where it was.** The geocoder's confidence rule
  (`Reventless.Geocoding`), the `Geolocation.t` union a view carries, the object
  store's mint, presign and expiry are in `reventless-spec` and the platform
  packages. A view's field type cannot have its constructor in an optional package.

A trait is four things:

| Part | What it is | Where in the package |
|---|---|---|
| **Rules** | Ordinary compiled ReScript: the trait's decision and fold logic over its own types, knowing nothing about your entity | `src/<Trait>_<Rules>.res` |
| **Host contract** | A `module type Binding`: what your aggregate or slice must expose for the rules to be checked against it | `src/<Trait>.res` |
| **Spec fragments** | The constructors, annotations, state fields and delegating bodies you paste into your own spec files, with placeholders | `spec-fragments/*.res.tpl` |
| **Conformance suite** | A functor that registers Jest scenarios over your binding — the trait's rules, run against *your* graft | `src/<Trait>_Conformance.res` |

The graft becomes ordinary source in your plugin: it compiles with your plugin, is
scanned by the plugin generator like any other file, and provisions what its
annotations declare. The trait is a **runtime dependency** of that plugin — its
`.res.mjs` is imported wherever your handlers run — so it belongs in `dependencies`,
not `devDependencies`.

The framework packages never import a trait; only applications do. Both traits
depend on `reventless-spec` and `reventless-gwt` and nothing else.

## Where the boundary falls

Take the geocoding trait's staleness and redelivery guards. In the trait they are
written once, over a three-field view of whatever the host holds:

```rescript
let onLocationReport = (r, ~location, ~resolvedFrom) =>
  if resolvedFrom != r.subject {
    Ignore
  } else if r.location == Some(location) && r.resolvedFrom == Some(resolvedFrom) {
    Ignore
  } else {
    Append
  }
```

In `Customer_Behavior.res` the corresponding `decide` arm names the host's own
command and the host's own event, and delegates the judgement:

```rescript
| (Active(s), SetLocation({location, resolvedFrom})) =>
  Guards.onLocationReport(
    resolution(s.address, s.location, s.locationResolvedFrom),
    ~location,
    ~resolvedFrom,
  )->appended(LocationSet({location, resolvedFrom}))
```

`resolution` and `appended` are four-line host-local adapters, also in the fragment.
Everything above the delegation is yours; everything below it is the trait's.

**One rule for aggregate hosts: trait types in transient state, host types in
persisted state.** An aggregate's state is snapshotted, so a trait-owned record
embedded in it would turn every trait release that reshaped it into a snapshot
migration — hence `Customer` keeps `location` and `locationResolvedFrom` as its own
fields and builds the trait's view per call. A StateChangeSlice's state is refolded
per decision and never stored, so the attachment hosts embed the trait's `Set.t`
directly.

## What a spec fragment is, and how it is applied

A fragment is **not** a ReScript file and is not compiled — the `.tpl` suffix keeps
it out of the build. It is a fragment of a ReScript file: the declarations a host
needs, with double-braced placeholders where the host's own names go. Its first line
says which file of yours the fragment belongs in, and `// ---` rules inside it
separate the pieces that go into different parts of that file.

The placeholders are the names that differ between hosts — nothing else does:

| Placeholder | Meaning | In the geocoding example |
|---|---|---|
| `Entity` | the host aggregate or entity | `Customer` |
| `entityId` | its id field on events | `customerId` |
| `Subject` / `subject` | the field being geocoded, in both spellings | `Address` / `address` |
| `Created` | the event that brings the entity into existence | `Registered` |
| `Slice` | the outbound slice you are creating | `GeocodeCustomerAddress` |

Applying a fragment is a search-and-replace followed by a paste. Expect small edits
after it — a comment that now reads "a address" wants its article fixed — and edits
where the fragment says it cannot know your host: the attachment trait's `decide`
carries the line `// The host's own refusal (archived, discontinued …) goes here.`
File naming follows the usual convention, so the attachment slice fragment is pasted
as `StateChangeSlice/<Entity>Images.res`.

Pasting is by hand on purpose. A generator would have to know your file layout and
where in an existing `switch` an arm belongs, and you would still have to read the
result. What keeps a hand-pasted spec surface honest is the conformance suite: it
runs against *your* file, not the fragment.

## The two traits

### `@reventlessdev/trait-address-geocoding`

The reusable middle of *turning an aggregate's address into a point without
corrupting the aggregate's data*. What a geocoder's answer **means** — the
confidence rule, the `Geolocation.t` union a view carries — is the framework's
(`Reventless.Geocoding`, `Reventless.Geolocation`). The trait owns how that answer
is **grafted** onto an aggregate:

- **`resolvedFrom` is a staleness token** — an answer for an address the entity has
  since changed is dropped, not applied.
- **Redelivery is a no-op** — the outbound slice re-publishes on every heartbeat
  until its TODO clears, so an unchanged answer must not append a duplicate event.
- **An outage is not a verdict** — `Unavailable` retries; `NoMatch` records a fact.
- **The stand-down** — a client that supplies address and point together is not
  raced by the geocoder: the pair-supplying event is not in the slice's consumed set.
- **Two state fields** (`location` + `locationResolvedFrom`), because never-asked,
  found, and tried-and-found-wanting do not fit in one `option`.

The first four are `AddressGeocoding_Guards` and `AddressGeocoding_Translate`; the
fifth is a shape your state carries. Shape: two `@noApi` commands and three events on
the host aggregate, one `OutboundTranslationSlice` keyed `{entityId}:{address}`, one
`Geolocation.t` field on the read model. Requires the `geocode` capability from the
platform (`Capability_Geocoding_AwsLocation` on AWS; the local platform answers
`Unavailable`, which keeps the work queued and visible).

### `@reventlessdev/trait-file-attachment`

An **ordered set of stored files** on an entity — attach, remove, choose the
primary, caption — as domain facts. Storage itself is the platform's:
`UploadableImage.t` names the store, and mint, presign and pending-expiry are
already there. The trait owns the rules of the *set*, in `FileAttachment_Set`:

- **Attach and remove are idempotent**; a removed ref can come back.
- **The primary is one of the set.** Until one is chosen the first attached
  stands in; choosing the current primary appends nothing; removing the chosen one
  lets the first remaining stand in again.
- **A caption belongs to a member** — refused for a ref not in the set, a no-op
  when repeated.
- **The read model carries the primary as one string beside the set**, so a card
  or a gallery tile has an image to draw without reading the set. The projection
  calls the same `primaryOf` the decision side uses, so the two cannot disagree.

Shape: one `StateChangeSlice` per host with four commands
(`Attach…`, `Remove…`, `SetPrimary…`, `Set…AltText`), four events, and two view
fields (`<file>?` for the primary, `<file>s: array<{…}>` for the set). Unlike the
geocoding trait it writes nothing back into another component — the graft *is*
the host's slice.

## How the online-shop example uses them

The hybrid example (`examples/online-shop-hybrid`) is the specimen host of both.

| Trait | Host | Graft | Conformance binding |
|---|---|---|---|
| address-geocoding | `Customer` aggregate (Ordering) | the `SetLocation` / `MarkAddressUnresolvable` commands, `LocationSet` / `AddressLocated` / `AddressUnresolvable` events, the `GeocodeCustomerAddress` outbound slice, `Customers.geolocation` | `ordering/tests/Customer/AddressGeocodingConformance_GWT.res` |
| file-attachment | `Product` (Catalog) | the `ProductImages` slice, `Products.productImage` + `Products.productImages` | `catalog/tests/Product/ProductImagesConformance_GWT.res` |
| file-attachment | `Category` (Catalog) | the `CategoryImages` slice, `Categories.categoryImage` + `Categories.categoryImages` | `catalog/tests/Category/CategoryImagesConformance_GWT.res` |

Two hosts for the attachment trait is deliberate: a contract validated against one
host is a description of that host. The second is what makes the rules a contract —
and now that both call the same module, it is also what proves the module is host-
agnostic rather than `Product`'s code with a general name.

The host's *own* rules stay in the host's ordinary GWT files — `ProductImages_GWT.res`
asserts that a discontinued product refuses attachments; the trait's suite has no
opinion on that. What the suite covers is deleted from the host's tests rather than
kept in parallel, so each rule has one source of truth.

## Using a trait in your own application

1. **Add the dependency** to the plugin package that will host the graft —
   `@reventlessdev/trait-file-attachment` in `package.json`'s `dependencies` and in
   the `dependencies` list of `rescript.json`. The trait's sources are compiled by
   your build; there is no `lib/` to install.

2. **Apply the spec fragments**: replace the placeholders, paste each piece into the
   file its first line names, and add your host's own refusal where the fragment
   marks the spot (a retired state, a terminal lifecycle). What you paste declares
   and delegates; the rules it delegates to are not copied.

   One thing the attachment fragments insist on: the member field is **named for
   its store** (`productImage` inside the set's record, not `image`), because the
   ppx derives the object store from the field name and provisions it.

3. **Bind the host and run the suite.** In a `tests/…/<Host>Conformance_GWT.res`
   file, write the binding — constructors for your host's events and commands, two
   distinct fixture values — and register the suite:

   ```rescript
   module Binding = {
     type ref = string
     let refA = "/uploads/…/a.jpg"
     let refB = "/uploads/…/b.jpg"

     module Spec = ProductImages
     module Behavior = ProductImages_Behavior

     let created: array<ProductImages.consumedEvent> = [ProductAdded({productId: "p1"})]
     let attach = ref => ProductImages.AttachProductImage({productId: "p1", productImage: ref})
     // … the remaining constructors; `module type Binding` lists every one
   }

   module Conformance = TraitFileAttachment.FileAttachment_Conformance.Make(Binding)

   Conformance.register()
   ```

   The file matches your plugin's `*_GWT.res.mjs` test glob, so `pnpm test` runs it
   with everything else. A red assertion names the rule your mapping broke.

4. **Provide what the trait requires.** The geocoding trait needs the `geocode`
   capability on the platform; the attachment trait needs the object store the
   field name derives, which the plugin's capability manifest declares for you.

### What the suite does and does not check

The suite asserts the trait's rules against your `decide` / `evolve` (and, for
geocoding, your slice's `translate` driven by a stub geocoder) — which now means it
is checking your *mapping* onto the rules rather than a copy of them. It does **not**
assert your host's lifecycle rules, your authorization, or your projection — those
are yours, and belong in your own scenarios. For the geocoding trait, the
stand-down is checked as a *contract* rather than a runtime scenario: the slice's
consumed-event set must equal the triggers the binding names and contain none of
the pair-supplying events.

### Limits worth knowing

- **A rule change is a behavior change for every host.** That is the point, and it
  is also the cost: read a trait's release notes the way you would read a framework
  upgrade, and let the conformance suite tell you what moved.
- **Auto UI shows the primary.** The shell's card, gallery and reference cell read
  one image field per row; a per-row gallery over the whole set is UI work.
- **The empty-tile upload slot abstains** on an attachment host: the shell resolves
  a slot's setter as *the one command carrying exactly one field of the store*, and
  the attachment slice has four. Attach through the command form instead.
- **Conformance scenarios are not harvested** by the lifecycle-model check, which
  reads the sidecar the ppx writes for `@@reventless.gwt` files. Keep your host's
  own `@transition`-bearing scenarios in ordinary GWT files, spelled as literals.

### Where the packages live

`traits/` in the framework repository, published under the same licence and release
train as the framework. `pnpm run check:traits` packs each trait and builds its
specimen host from the tarball — the check that proves the package boundary is real,
and, now that the host compiles and imports the trait's rule module, that the
published tarball carries everything the host links against.
