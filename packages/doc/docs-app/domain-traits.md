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
  read off *your* source. You do not transcribe that surface, though: where the
  trait's own constructors fit, you **spread** them and the compiler carries them;
  where they do not, the trait's emitter writes the files and prints the arms.
- **What was already shared stays where it was.** The geocoder's confidence rule
  (`Reventless.Geocoding`), the `Geolocation.t` union a view carries, the object
  store's mint, presign and expiry are in `reventless-spec` and the platform
  packages. A view's field type cannot have its constructor in an optional package.

A trait is four things:

| Part | What it is | Where in the package |
|---|---|---|
| **Rules** | Ordinary compiled ReScript: the trait's decision and fold logic over its own types, knowing nothing about your entity | `src/<Trait>_<Rules>.res` |
| **Host contract** | A `module type Binding`: what your aggregate or slice must expose for the rules to be checked against it | `src/<Trait>.res` |
| **Emitter** | Compiled ReScript with a validated config: hand it your names and it writes the spec files the graft owns, and prints the arms for files you already own | `src/<Trait>_Scaffold.res` |
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

## How a graft arrives: spread, emit, or paste

There are three ways a declaration gets into your plugin, and a trait uses whichever
its host shape allows. The choice is not stylistic — it follows from a question you
already answered before you modelled anything: **aggregate or DCB slice?**

| Route | When | What it costs you |
|---|---|---|
| **Spread** | The trait's own constructors fit your vocabulary | one line; the compiler carries the names, the annotations and the schema |
| **Emit** | The graft is a component you do not have yet | one command; the file is yours from the moment it lands |
| **Paste** | The arms belong inside a file you already own | a printed patch you place |

### Spread

ReScript variant spreads splice one type's constructors into another:

```rescript
type event =
  | Registered({email: string, address: string})
  | ...TraitAddressGeocoding.AddressGeocoding.events
  | Deactivated
```

Your `evolve` and your projections then match `LocationSet`, `AddressUpdated` and the
rest **unqualified**, exactly as if you had written them. sury splices the schema flat
— the generated code concatenates the trait's `anyOf` — so the wire format and the
generated GraphQL are identical to hand-written arms, not nested. Annotations the
trait declared travel too: the geocoding trait's two report commands are `@noApi`, and
a host that spreads them does not publish them.

A spread cannot **rename** what it splices, and that is the whole of its limit. The
trait's constructors fix the word `Address` and the type `string`; a host that calls
the field something else, or types it differently, declares its own arms instead and
gets the same rules, the same contract and the same conformance suite.

Why this works for an aggregate and not for a DCB slice: in a DCB plugin a command
name and an event name are **routing keys over the whole plugin**, while in the
aggregate approach they are scoped to the component that declares them. A spread
cannot rename what it splices, so a trait shipping constructors into a DCB slice
would put its own fixed names into that shared namespace and collide with the next
host — which is exactly why the emitter writes them instead, host-qualified
(`AttachProductImage` / `AttachCategoryImage`), and why one trait can be grafted
onto two entities of the same plugin.

[Aggregate vs DCB: Naming](./aggregate-vs-dcb-decision-guide.md#naming-what-a-name-means-in-each-approach)
has the mechanism, including the part that matters if you ever consider qualifying
those names: commands and events are both routing keys for *opposite* reasons, and
only one of them could be changed.

### Emit

Each trait ships an emitter: compiled ReScript with a config validated by its own
schema. `graft-trait` resolves the trait by name from your `node_modules`, runs it,
writes the files the graft owns and prints the rest.

Because the config is validated by the trait, a misspelled key is a decode error
naming the key, before anything is written — not a placeholder that survives into a
file and fails at compile. And because the emitter is compiled with the trait, its
output can be built and run: `pnpm run check:traits` packs each trait, installs it
from the tarball, emits a graft, builds it and runs the trait's own conformance suite
against what was emitted.

That last property is what retired the `.res.tpl` fragments this section used to
describe. A template compiles nowhere and is checked by nothing; it is transcribed
from a working host and drifts from it in silence. The geocoding template had already
drifted — it declared the creation event as carrying the address alone, while the one
host that applied it carries `Registered({email, address})`, a payload the template
had no way to express and no way to notice was missing.

### Paste

What is never emitted is an arm that belongs inside a file you already own: an arm in
an ordered `switch`, a field on an existing state, a case in a projection. Placing one
is an AST operation, and a text splice into the wrong arm is a bug the compiler cannot
see. Those are **printed** for you to place.

Policy is never emitted either. Which states the graft is legal in, which refusal
comes first, what your own events do to your own state — those differ across every
host (one refuses on a three-state shelf, another on a boolean), and expressing them
in a config is how a scaffolder acquires a policy language nobody asked for. They
arrive as `TODO(graft)` markers, and you write ReScript, which is better at this than
any config could be. A graft with no extra refusal is a complete graft, so leaving a
marker alone is legitimate.

## The three traits

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

### `@reventlessdev/trait-attachments`

An **ordered set of stored files** on an entity — attach, remove, choose the
primary, caption — as domain facts. Storage itself is the platform's:
`UploadableImage.t` names the store, and mint, presign and pending-expiry are
already there. The trait owns the rules of the *set*, in `Attachments_Rules`:

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

### `@reventlessdev/trait-notification`

**Telling somebody something happened.** A per-recipient contact directory, a
kind × channel subscription matrix, and the decision — per request — whether that
becomes an addressed message. Delivery is the platform's: the send slice reaches
`Reventless.Capabilities.messaging` and takes its retry split from
`Reventless.Messaging.retriable`. The trait owns the decision, in
`Notification_Rules`:

- **The address is resolved when the message is composed**, off the directory, not
  carried by the occurrence. Putting it on the occurrence would freeze a mutable
  fact into an append-only log, so a recipient who changed their address would have
  old occurrences confirmed to the old one.
- **An absent choice falls back to a posture the host supplies.** The rule is the
  trait's; the table is not — whether an unheard-from recipient should be notified
  is per kind and per host.
- **Three ways to send nothing, and they stay three facts.** Declined is
  `Suppressed`; enabled-but-unaddressable and never-announced are both
  `Undeliverable`. One fact for all of them would hide every delivery gap behind a
  legitimate preference.
- **Re-announcing an address already on file appends nothing** — safe because the
  relay's row completes on the publish rather than on an event coming back.

Shape: this is the trait that **brings its own components** rather than adding arms
to something the host had — a `StateChangeSlice`, an `OutboundTranslationSlice` for
the send, and two views, none of which existed before. So the emitter writes five
files whole and the host's part shrinks to two **relays**: one saying which of its
events announce a contact, one saying which occurrence earns a notification and
what it says. Those are printed, not written — what a host's events mean is the one
thing a trait cannot be told in names. It writes nothing back into the host at all.

## How the online-shop example uses them

The hybrid example (`examples/online-shop-hybrid`) is the specimen host of all three.

| Trait | Host | Graft | Conformance binding |
|---|---|---|---|
| address-geocoding | `Customer` aggregate (Ordering) | the `SetLocation` / `MarkAddressUnresolvable` commands, `LocationSet` / `AddressLocated` / `AddressUnresolvable` events, the `GeocodeCustomerAddress` outbound slice, `Customers.geolocation` | `ordering/tests/Customer/AddressGeocodingConformance_GWT.res` |
| attachments | `Product` (Catalog) | the `ProductImages` slice, `Products.productImage` + `Products.productImages` | `catalog/tests/Product/ProductImagesConformance_GWT.res` |
| notification | Ordering, no host component at all | the `NotificationPreferences` slice, `SendNotification`, and the `NotificationDeliveries` / `NotificationSubscriptions` views — plus the two relays the host writes | `ordering/tests/Notification/NotificationConformance_GWT.res` |
| attachments | `Category` (Catalog) | the `CategoryImages` slice, `Categories.categoryImage` + `Categories.categoryImages` | `catalog/tests/Category/CategoryImagesConformance_GWT.res` |

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
   `@reventlessdev/trait-attachments` in `package.json`'s `dependencies` and in
   the `dependencies` list of `rescript.json`. The trait's sources are compiled by
   your build; there is no `lib/` to install.

2. **Run the emitter.** `graft-trait` resolves the trait by name from your own
   `node_modules` and runs its scaffold. Every `--key` past the two paths is a field
   of that trait's config, and the trait validates them — so a misspelled key is
   named before anything is written, and running it with none tells you what it
   wants.

   ```sh
   pnpm exec graft-trait @reventlessdev/trait-attachments \
     --into src/Product --tests tests/Product \
     --entity Product --entityId productId --noun Image \
     --file productImage --created ProductAdded --view Products
   ```

   One thing the attachment config insists on: the member field is **named for its
   store** (`productImage`, not `image`), because the ppx derives the object store
   from the field name and provisions it.

   What it writes is yours from the moment it lands — nothing regenerates it, and
   `graft-trait` refuses to overwrite. What it *prints* are the arms for files you
   already own; those are printed rather than written because placing an arm in an
   ordered `switch` is an AST operation, and a text splice into the wrong arm is a
   bug the compiler cannot see.

3. **Fill the `TODO(graft)` markers, and paste the patches.** The markers are your
   policy: which states the graft is legal in, which refusal comes first, what your
   own events do to your own state. The emitter deliberately does not write them —
   expressing them in a config is how a scaffolder acquires a policy language nobody
   asked for, and ReScript is better at this than any config could be. A graft with
   no extra refusal is a complete graft, so leaving a marker alone is legitimate.

4. **Run the conformance suite.** The binding is emitted whole — every name in it is
   one the graft already declared — so `tests/…/<Host>Conformance_GWT.res` is there
   already and needs no hand-written file. It matches your plugin's `*_GWT.res.mjs`
   glob, so `pnpm test` runs it with everything else, and a red assertion names the
   rule your mapping broke.

5. **Provide what the trait requires.** The geocoding trait needs the `geocode`
   capability on the platform, which its emitted slice declares as `capabilityNeeds`
   so a deploy that provisions nothing is refused rather than silently degraded; the
   attachment trait needs the object store the field name derives, which the plugin's
   capability manifest declares for you.

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
train as the framework. `pnpm run check:traits` packs each trait, installs it from the
tarball beside a copy of its specimen host, emits a graft, builds it and runs the
trait's own conformance suite against what was emitted. Workspace resolution hides
exactly the defects the first half catches — a `files` allowlist that omits what the
consumer compiles, a tarball that needs `lib/`, a `.cmi` skew — and the second half is
the claim a template could never support: that the graft compiles and satisfies the
trait's rules with no host policy written at all.

## Extracting a trait out of code you already wrote

The install direction and the extract direction are the same four artifacts in
opposite orders. Installing, you add a dependency and the trait writes into your host.
Extracting, you start from a host that already works and lift the competency out of
it — and **the host you extract from is the emitter's first draft**, which is what
makes the last step mechanical rather than inventive.

Both shipped traits were built this way. Here is the order that worked.

**0. Decide it is a trait at all.** A competency worth extracting reappears across
domains, carries rules that are easy to get subtly wrong, and has a boundary you can
name in one sentence. If you cannot say what the trait refuses to know about your
host, you have a library, not a trait.

**1. Lift the rules.** Move the guard bodies and folds into a rules module written
over the trait's *own* types — a small view of whatever the host holds, not the host's
state record. The test: the module must compile with no knowledge of your entity. In
the geocoding trait this is a three-field `resolution`; in the attachments trait it is
the set itself. Your host keeps its state and its constructors and now *calls* the
module.

Do this first because it is the step that fails. If the rules will not separate from
the host's state, either the boundary is in the wrong place or the competency is not
one.

**2. Write the `Binding` over your host's constructors.** A `module type` naming what
a host must expose: its spec, its behavior, and one function per constructor the
rules reason about. Keep abstract whatever your host happens to have made concrete —
the geocoding trait's `subject` is abstract so the rules hold for any address-shaped
thing, even though its first host types it `string`.

**3. Promote your existing GWTs into the conformance functor.** You already wrote the
scenarios; they are in your host's test files, spelled with your constructors. Rewrite
each one over the binding instead. Then **delete the originals** — a rule the suite
covers must not also live in the host's tests, or the two drift and neither is the
source of truth. What stays in the host's own tests is what the trait has no opinion
on: your lifecycle refusals, your authorization, your projection.

At this point the trait works. It is a package your host depends on, and its suite
runs green against your host. Everything after this is about the *next* host.

**4. Decide what a second host can splice.** Ask the host-shape question. If the graft
is on an aggregate, the trait's events — and any `@noApi` commands — can be real
constructors a host spreads, and you should push as much as will fit: a trait should
own as much as it can, and narrowing one to fit a blocker is how competencies get
lost. If the graft is a DCB slice, the answer is none of them, and the emitter carries
the whole declaration surface.

**5. Parameterise your own files into the emitter.** Take the files the graft owns —
the ones you would have to write again for host two — and replace your host's names
with config fields. This is transcription, not design: you already have the working
text. Everything that is a *name* becomes config; everything that is control flow
stays code; everything that is *policy* becomes a `TODO(graft)` marker. Then print,
rather than write, the arms that go into files a host already owns.

**6. Prove it, by deleting your own work and re-emitting it.** Add the trait to
`check:traits`. For a trait whose graft is a new component, emit onto a fresh entity
the specimen host does not have. For a trait grafted onto an aggregate, the check
**removes the files the trait owns from a scratch copy of the specimen host and emits
them back**, then builds and runs the conformance suite. Nothing is diffed — the
emitted files have to compile and conform, which is the property that matters, and a
diff would only push you toward an emitter that knows one host's policy.

This is the step that turns "we have a package" into "we have a trait", and it is
worth being strict about: when the geocoding emitter was first run this way, the code
it produced was byte-identical to the two files a person had written by hand a week
earlier, and the only differences were comments. That is the outcome to aim for — and
if you cannot get it, the residue is telling you which part of the graft is really
host policy.

**What is still asserted rather than demonstrated:** that this generalises. It is
written from three traits extracted by the same person in the same fortnight. The
first trait built by *installing* rather than extracting is the real test of it.

The third one did put the procedure under some strain, and both places are worth
knowing about. Step 1 held — the rules separated from the host on the first
attempt — but step 2 needed a member no other trait has: `posture`, the host's
answer to a question the rules cannot settle. A binding is not only constructors.
And step 5's "everything that is a name becomes config" broke once: which of a
host's events *mean* something is not a name, so those two files are printed with
their shape filled in and their meaning marked, rather than written.
