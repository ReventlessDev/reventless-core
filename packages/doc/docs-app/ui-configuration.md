# Configuring the Generated UI

Reventless generates a working user interface from your plugin specs — no per-plugin
bundle, no hand-written forms. This guide describes every knob that shapes what that
UI shows and how it behaves. The `online-shop-hybrid` example (Catalog + Ordering)
is the running illustration throughout.

## 1. Four layers

Configuration arrives from four independent places. They compose; none of them
overrides another, because each answers a different question.

```
┌─ Layer 1 ── Annotations on your spec types ──────────────────────────┐
│  What does this field MEAN?                                          │
│  @lifecycle, @displayName, @hidden, @metric, semantic types …        │
│  → travels with the component, wherever it is rendered               │
└──────────────────────────────────────────────────────────────────────┘
┌─ Layer 2 ── Baked manifest (bakedManifest) ──────────────────────────┐
│  Which components does THIS deployment's audience see?               │
│  → component-manifest.json, one file per journey                     │
└──────────────────────────────────────────────────────────────────────┘
┌─ Layer 3 ── UI hints (ui-hints.json) ────────────────────────────────┐
│  What is this view CALLED and where does it sit in the nav?          │
│  → ui-hints.json, served beside the shell                            │
└──────────────────────────────────────────────────────────────────────┘
┌─ Layer 4 ── Deployment choices (hostUiBundle / shellConfig) ─────────┐
│  What is this APP, and which optional features load?                 │
│  → config.json, computed at deploy time                              │
└──────────────────────────────────────────────────────────────────────┘
```

A rough rule for deciding where something belongs: if it is true of the **domain**,
annotate the type (layer 1). If it is true of this **deployment** — its name, its
audience, its nav — it belongs in layers 2–4, where a second deployment of the same
plugins can answer differently.

:::caution None of this is authorization
Layers 2 and 3 are **curation and presentation**. Leaving a component out of a
manifest keeps it out of a menu; it does not make it any less callable. The server
decides what a caller may do, per query and per mutation, and decides it the same
way whether or not a component appears in any manifest. Use
`@@reventless.authorize` and `@owner` for the actual gate — see
[Identity](./common-modules/identity.md).
:::

---

## 2. Layer 1 — annotations on spec types

Annotations on a `@schema type state` record tell the UI what your fields *mean*.
None of them changes your projection or the data you store — they are declarations
*about* the data, and they travel with it.

They work on **ReadModel**, **ReadModelStream**, **StateViewSlice** and
**StateViewSliceStream** spec files (any file carrying `@@reventless.spec` with a
`@schema type state`). Some also work on command variants, noted where they do.

### 2.1 Naming the record

**`@displayName`** marks the field (or fields) that name a row. One or more fields
may carry it; the values are composed into a projected `displayName` column.
`@displayName("sep")` sets the separator for composite labels.

```rescript
@schema
type state = {
  customerId: string,
  @displayName email: string,
  address: string,
}
```

With no annotation the framework guesses, in this order:

| | How the label is chosen |
|---|---|
| 1 | a `@displayName` annotation — you said so |
| 2 | a field named `name`, `title`, `label` or `displayName` (case-insensitive, exact) |
| 3 | the first label-shaped field in declaration order |
| 4 | nothing suitable — falls back to `id`, with a logged warning |

Step 3 is worth annotating your way out of: the row name changes whenever a field
is inserted above the old one. Adding a `placedAt` field so date views have
something to key off would rename every order to a timestamp.

### 2.2 Lifecycle

The field holding the entity's lifecycle state. The generated view sections and
badges rows by it, and it drives the per-row command menu — each command's
`@allowedStates` is filtered against the row's current state.

Name the field `lifecycle` and the name is the declaration:

```rescript
@schema type lifecycle = Placed | Shipped | Cancelled

@schema
type state = {
  orderId: string,
  lifecycle: lifecycle,
}
```

**`@lifecycle`** declares it for a record whose field is honestly called something
else, and calling it `lifecycle` would assert something false:

```rescript
@schema type accountStatus = Active | Deactivated

@schema
type state = {
  customerId: string,
  @lifecycle accountStatus: accountStatus,
}
```

Resolution order: (1) the annotated field; (2) a field literally named `lifecycle`
whose shape is an enum; (3) none, and the per-row filter is inert. At most one
`@lifecycle` per record — a duplicate is a compile error.

**Not every enum ending in `Status` is one.** A customer record may also carry a
`locationStatus: Pending | Located | Unresolvable` tracking whether a geocoder has
turned the address into a point. It is enum-shaped and it is called a status, and
it is still not the lifecycle: no command branches on it and no lifecycle passes
through it. It is a background job's progress. Annotating it would section the list
by how far a geocoder got and filter the command menu against states no command
mentions. This is why the annotation is keyed on `lifecycle` rather than on
`status` — `status` is a promiscuous name, and a record often has several.

### 2.3 List and summary presentation

| Annotation | Effect |
|---|---|
| `@summary` | always include this field in summary/list views |
| `@hidden` | suppress this field from summary/list views |
| `@groupBy` | section the list view by this field; for an enum, the declaration order is the section order |

`@hidden` and `@summary` on the same field is a compile error. At most one
`@groupBy` per record.

`@hidden` is for fields that are only meaningful once a human is already looking
into a row:

```rescript
@hidden locationNote: option<string>,
```

### 2.4 Hierarchical rendering

| Annotation | Effect |
|---|---|
| `@collapsed` | render an object-typed field as an inline summary instead of expanding it |
| `@drillTarget("SliceName")` | navigate to the named view instead of expanding inline — typically on `array<…>` fields |
| `@drillTarget({slice: "SliceName", key: "field1/field2"})` | same, plus a key path naming which sub-fields of each array element form the drill-down key |

### 2.5 Dashboard metrics

**`@metric`** on a numeric field declares an aggregation, and the generated
dashboard folds it into its metric list — so a plugin gets a Dashboard page from
its schema alone.

```rescript
@metric("sum") orderCount: int,
@metric({aggregate: "sum", label: "Revenue"}) total: Reventless.Money.t,
```

`aggregate` is one of `count`, `sum`, `avg`. An omitted `label` lets the UI derive
one from the field name.

### 2.6 Semantics — what a value *is*

The strongest form of UI configuration is a typed field. A semantic type carries
its meaning in the type system, so the compiler checks it and it cannot drift from
the field's shape.

```rescript
price: Reventless.Money.t,                            // currency-aware formatting
location: option<Reventless.GeoPoint.t>,              // a map pin, from a declaration
deliveryWindow: option<Reventless.DateRange.t>,       // one span, not a guessed pair
placedAt: @s.matches(Reventless.DateTime.string) string,  // calendar / timeline views
```

Available in `Reventless.*`: `Money`, `Currency`, `GeoPoint`, `DateRange`,
`DateTime`, `Duration`, `Bytes`, `Color`, `Email`, `Phone`, `Percent`, `Url`,
`StorageRef`, `Offload`.

Why this beats a name-based guess: `GeoPoint.t` says *one declared point*, so the
view drops a pin per row rather than hunting for a `lat`/`lng` pair among the
numeric fields. `DateRange.t` says *one span*, so a scheduler lays out a bar
directly instead of pairing `start*`/`end*` by name.

**`@semantic("id")`** says the same thing about a field whose type cannot. Reach
for it when you are not in a position to change the type; the vocabulary is the
UI's, so a name it does not know is not caught at compile time. Where a field has
both, the type wins and the disagreement is logged rather than quietly resolved.

### 2.7 References and object stores

**`@ref("Entity")`** (or `@ref("Plugin.Entity")`) marks a `string` or
`array<string>` field as a cross-entity reference. The generated command form
renders an entity picker instead of a free-text box. It works on **command**
variants, which is where it earns its keep:

```rescript
@ref("AvailableProducts") productIds: array<string>,
```

A `@ref` also drags its target into the shell's reach even when the target appears
in no manifest — the picker needs something to pick from.

**`@storageRef("store")`** marks a field holding a store-minted ref path, and
**`@offload("store")`** marks an inline-or-reference field whose large values are
content-addressed to a store. Both provision the store and give the generated form
an upload control. See
[`@storageRef`, `@offload`](./reventless-ppx.md) in the PPX guide for the field
markers, and §5 for the deployment side that provisions the store.

### 2.8 Query capability — what the UI can filter and sort by

These shape the generated GraphQL surface, and therefore what the list view can
offer:

| Annotation | Gives the UI |
|---|---|
| `@id`, `@compositeId`, `@subId`, `@compositeSubId` | key filters and ordering |
| `@index`, `@indexSubId` | filter + order by a secondary index |
| `@scan` | opt-in equality filter on a field with no backing index |
| `@scanSort` | opt-in sort on a field with no backing sort key |
| `@resolves`, `@resolvesMany` | cross-table resolvers — linked entities in the detail view |

An `@index` on a field that *names another entity* is worth calling out, because it
buys more than a filter box. `@index categoryId` on a product is what lets a shell
offer the category's own page a list of its products: the filter it needs
(`categoryIdEq`) exists, and the annotation reaches the client as
`x-reventless-index` on the field's JSON Schema, so the shell can discover that the
server will answer rather than fetching a page and narrowing it locally.

`@scan` and `@scanSort` are free on the local platform and cost `O(n)` on
DynamoDB-backed adapters. The annotation *is* the signal that the read model is
small enough, or that the cost is accepted. See
[the GraphQL API guide](./graphql-api-guide.md) for the exact generated arguments.

`@id` is usually unnecessary — the key is inferred from the component name. Reach
for it when inference has nothing to go on:

```rescript
// Two `*Id` fields, and the component name `ProductDemand` yields no matching
// field. Without @id the queryable gets no key filter and no order-by at all.
@schema
type state = {@id productId: string, name: string, categoryId: string, orderCount: int}
```

### 2.9 Component-level declarations

**`@@reventless.visibility(Internal)`** keeps a read model or state-view slice out
of the generated UI — no page, no panel, no menu entry. It stays queryable, and
authorization is untouched: this is a UX hint, not a boundary. Use it for
denormalised mirrors that exist as lookup targets rather than as surfaces.

**`@live(true | false)`** goes on the `@schema type state` declaration itself, not
on a field. `false` marks an investigative or historical view where a Live control
makes no sense; `true` marks an operational one. Leave it out and the UI applies
its own default.

```rescript
@live(false)
@schema
type state = { … }
```

**`@@reventless.authorize(AllowGroups([…]))`** is the real gate, and it is worth
stating next to the hints because the two are easy to confuse. `visibility`
decides what a menu shows; `authorize` decides what the server answers.

### 2.10 Ownership

**`@owner`** names the field holding the id of the principal a record belongs to.
On a command the write path overwrites it with the authenticated caller's id; on a
queryable's state, reads narrow to the caller's own rows.

```rescript
// on the view
@owner customerId: string,

// on the command
@noDcbTag @owner customerId: string,
```

For the UI this decides two things: whether the generated form asks for the owner
field or supplies it, and whether an owner column is worth showing. Who is exempt
is deployment configuration (`elevatedGroups`), never part of the annotation —
see §5.3.

### 2.11 Retirement

**`@retired`** names the state that withdraws a row from ordinary use — a
deactivated customer, an archived category. It has two forms, and which one a
record wants follows from whether it already has a lifecycle.

**On a lifecycle constructor**, which is the marker's home. The state's own name is
what it means, so the annotation takes no payload:

```rescript
@schema type accountStatus = Active | @retired Deactivated

@schema
type state = {
  @id customerId: string,
  displayName: string,
  @lifecycle accountStatus: accountStatus,
}
```

**On a boolean field**, where the field itself is the state:

```rescript
@retired deactivated: bool,

// or, naming the state and asking for it in the negative too
@retired({label: "Archived", showWhenFalse: true}) archived: bool,
```

Prefer the constructor form wherever a lifecycle already exists. A record with
`accountStatus: Active | Deactivated` *and* a `deactivated: bool` beside it states
the same fact twice with nothing keeping the two in step — which is the shape the
lifecycle was introduced to remove.

For the UI both say the same thing: render retirement as a *state of the row* — a
badge, a dimmed row, a filter toggle — rather than as one more boolean column. The
annotation emits `x-reventless-retired` on the field's JSON Schema. `label` and
`showWhenFalse` are the boolean form's payload: an absent label means "not stated",
so derive one from the field name, and `showWhenFalse` asks for the marker in the
negative state too, since by default a flag is worth showing only when it is true.
The constructor form needs neither — the state is already named, and a row that is
not retired is in some other named state.

The rest is not a hint. Rows in the retired state — the flag true, or the lifecycle
sitting on the marked constructor — are **withheld server-side** from
callers who are not exempt — from the list query, the single-entity query, and
the payload of a live change frame, which downgrades to metadata-only so every
subscriber refetches and the query layer answers per caller. The UI cannot show
what the server does not return, and does not have to filter anything itself.

An exempt caller reaches the archive by passing `includeRetired: true` — a
top-level argument beside the paging ones, not a filter field, and accepted on
every door that answers rows: the list, the single-entity, the by-ids and the
by-index one alike, so a row seen in the archive can also be opened and can also
be looked up. Elevation alone does not lift the restriction; the caller has to
ask. A non-exempt caller passing it is ignored rather than refused.
Who is exempt is the same `elevatedGroups` that governs ownership (§5.3) — one
declaration, so two views cannot disagree about who an operator is.

### A retired row keeps its name

Withholding a row answers "what may this caller browse". It also answers, unasked,
"what is the row this caller is already holding a reference to called" — and an
order that names a product the catalog has archived should not lose the name of
what was bought.

`@namedWhenRetired` on the `@schema type state` declaration separates the two. It
takes no payload, and its presence says: a reference to a retired row of this
record still resolves. The generated **reference door**, `{list}Refs(ids)`, then
answers any caller with

```graphql
type Catalog_ProductRef { id: ID!, label: String!, retired: Boolean!, retiredState: String }
```

and nothing else — no other field, and no other door. `retiredState` names the
state that withdrew the row (`"Archived"`, `"Discontinued"`) for the state form,
and is null for a live row and for the boolean form, where the field *is* the
state.

Three things it does not do. It does not widen the list, the single-entity read,
the index reads or the live frame. It does not lift **ownership**: a retired row
that is owner-scoped is still named to its owner alone, which is why a
deactivated customer does not become a name oracle for anyone holding a customer
id. And it is not what makes the door exist — the door is generated for every
view, so that adding or removing the annotation is not a breaking schema change;
without it, the door narrows retired rows exactly as every other door does.

The generated UI reads this: a reference cell resolves the archived row's name and
puts the state beside it as a badge, the same badge the catalog's own list shows.
It renders the name unlinked for a caller who could not open the row anyway,
since the single-entity door still refuses one without `includeRetired`.

At most one `@retired` per record, in either form. The boolean form takes a `bool`
or `option<bool>` field and anything else is a compile error; the constructor form
takes no payload, and `label` or `showWhenFalse` on one is a compile error naming
the boolean form as their home. There is no fallback by field name — a boolean
called `archived` that nobody annotated hides nothing, and neither does a
constructor called `Archived`.

### 2.12 Tagged unions — one fact with several shapes

A field may hold a variant, which is the honest way to say a fact that takes
several shapes — the geocoder's answer is *pending on an address*, or *a point*,
or *unresolvable for a reason*, and those carry different data:

```rescript
@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({point: Reventless.GeoPoint.t})
  | Unresolvable({reason: string})

@schema
type state = {@id customerId: string, geolocation: geolocation}
```

The alternative — a point field, a status enum and a note field, with nine of the
twelve combinations illegal — is the same shape of mistake §2.11 removes for
retirement: several fields stating one fact, kept in step by hand.

**On the wire it is a GraphQL union**, one object type per arm, named
`<UnionName><Arm>`. Four things follow, and a reader that misses any of them
fails in a way that does not look like a schema mistake:

- **It cannot be selected bare.** Every consumer emits
  `... on Ordering_CustomersGeolocationLocated { point { lat lng } }`. A client
  that has not learned inline fragments sends an *invalid query*, not a degraded
  one — so generic union support has to ship before or with the first view that
  declares one.
- **The arm is `__typename`**, and it is stamped into the stored value at write
  time. So the row the live change channel delivers as raw JSON carries the same
  discriminator the query does, rather than a `TAG` the client has to translate.
- **The JSON Schema says so.** The field carries `x-reventless-union: "<Name>"`
  and a `oneOf` of arms, each with a `TAG` const and
  `x-reventless-union-member: "<UnionName><Arm>"` — the GraphQL type that arm is
  emitted as. The member name is published rather than left to be re-derived,
  and the `TAG` const is what distinguishes a union from a nullable object, which
  is also a `oneOf` of objects.
- **It is never a filter, sort, group or lifecycle field.** Those compare a field
  to a scalar; this one is an object whose shape depends on the row. The PPX
  refuses the annotations outright. "Show me the rows that are `Unresolvable`"
  wants a derived arm-name field beside the union.

For the UI the point of the type is that the arms are *different states*, not one
value that is sometimes absent: `Pending` waits and `Unresolvable` wants a human,
and a control that renders both as "no location" throws away the distinction the
type exists to make.

---

## 3. Layer 2 — the baked manifest

The shell needs to know which components exist for its audience. By default it
asks an admin-only API, which is fine for an operator console and no use for a
shop: customers are not administrators. A **baked manifest** answers the question
from a static file instead, so any audience can be served.

:::note What "baked" means
Baked in the sense of a baked image: computed once at deploy time and frozen into
an artifact, rather than resolved per request. The platform reads the plugin
structures it just registered, applies your include-list, and writes the result
beside `config.json` — through the *same* encoder the admin API uses, so a baked
entry and a served entry cannot drift, and an include-list naming everything
produces byte-identical output.

Two consequences worth holding on to. The file is settled before anyone logs in,
so it can say nothing about who is asking — which is why curation and
authorization stay separate concerns ("None of this is authorization", above).
And it changes only
when you deploy: adding a component to a plugin does not add it to a baked
surface until the next deploy re-bakes the file.
:::

You declare **what to include**; the framework fills in the detail from the
plugins you registered.

```rescript
let manifest: ReventlessInfra.Platform.bakedManifest = {
  components: [
    {plugin: "Catalog", views: ["Products", "Categories"], commands: [], derived: []},
    {plugin: "Ordering", views: ["Orders"],
     commands: ["PlaceOrder", "CancelOrder"], derived: []},
  ],
  journeys: [
    {
      group: "Merchandiser",
      components: [
        {plugin: "Catalog",
         views: ["Products", "Categories", "ProductDemand"],
         commands: ["AddProduct", "ChangeProductPrice", "AddCategory", "RenameCategory"],
         derived: []},
      ],
    },
    {
      group: "Fulfilment",
      components: [
        {plugin: "Ordering", views: ["Orders"],
         commands: ["ShipOrder", "CancelOrder"], derived: ["lifecycles", "canvas"]},
      ],
    },
  ],
}
```

**Selection semantics.** `views` / `commands` / `derived` unset means every public
component of that kind; set means exactly the named ones. It is an include-list,
not an exclude-list, so a component you add later has to be opted in and cannot
quietly widen a curated surface. **A name that matches nothing fails the deploy**,
naming it — a missing page is otherwise a symptom with no explanation.

**`derived` curates the pages built _across_ a plugin's views** rather than from
any one of them. Leave them out and your audience gets the views you named and
nothing else; name them and that audience gets them too:

| Kind | The page |
|---|---|
| `dashboard` | KPI cards and charts over the plugin's metrics |
| `lifecycles` | one state machine per view with a status enum and state-scoped commands |
| `canvas` | a calendar / timeline / map drawn across the plugin's dated or located views |
| `scheduler` | a resource-and-events lane join |

These are kinds, not page titles — you are answering "does this audience get
calendars", not naming the one called Deliveries. Naming a kind your plugin
generates no page for is fine: nothing appears until the views support it, so you
can state the intention before the schema catches up.

Curating `derived` is also how a menu stops showing groups named after your
plugins. A page built across several views belongs to none of them, so no `nav`
hint in §4 can rename or move it — the manifest is the only place to decide
whether an audience gets it at all.

**Journeys** are per-audience surfaces beside the default one. `group` is the
caller group the journey serves, and the shell picks the journey matching the role
the caller is acting as. `label` names it in the role switcher (defaults to the
group name); `key` names its file (defaults to one derived from the group, e.g.
`component-manifest-fulfilment.json`).

**`components` is the default journey** — what a caller matching no declared
journey gets. Always provide one: a local dev session without a login belongs to
no declared group, and with no default it would match nothing and render an empty
shell.

Both platforms honour the same declaration. Locally the files are written into the
shell's served directory at boot; on AWS the deploy grants the bake a write for
every key the declaration produces and the post-deploy bake writes them beside
`config.json`, which carries a group→url map (`journeyManifestUrls`) next to the
default `manifestUrl`.

Declare the manifest in a **platform-independent module**, and pass it from each
root. It answers "what does this app offer?", which is a fact about the app and is
the same whether it runs locally or on AWS.

### 3.1 Roles, and which question each mechanism answers

A **role is a group** — a Cognito group on AWS, a `groups:` entry in
`.reventless/users.yaml` locally. One vocabulary, but four independent mechanisms
read it, and confusing them is the main way this goes wrong:

| Question | Mechanism | Kind |
|---|---|---|
| What may this role **call**? | `@@reventless.authorize(AllowGroups([…]))` | enforced |
| Whose rows does it **read**? | `elevatedGroups` + `@owner` | enforced |
| What does it **see in the menu**? | `bakedManifest.journeys` | curation |
| Which of my roles am I **acting as**? | active-role token narrowing | enforced |

The permission vocabulary is `AllowGroups([…])`, `AllowAuthenticated`,
`AllowAnonymous` and `DenyAll`, evaluated against the resolved identity.

**Elevation and journeys are orthogonal**, and the hybrid shop is built to make
that visible:

| Role | Journey | Elevated | Why |
|---|---|---|---|
| `Shopper` | default (storefront) | no | reads its own orders |
| `Merchandiser` | `Merchandiser` | **no** | the catalog records no owner, so there is nothing to scope it out of |
| `Fulfilment` | `Fulfilment` | **yes** | working an order board means reading other people's orders as the ordinary job |
| `Admin` | default, plus the admin API | yes | everything |

`Merchandiser` and `Fulfilment` are the pair worth studying: "which surfaces does
this role use" and "does this role read across owners" are separate questions, and
each role answers exactly one of them affirmatively. Elevating a role that does not
need it buys nothing and widens what a stolen session reaches.

A journey does not imply an exemption from owner scoping, and an exemption does not
imply a journey. Two journeys that differ by one entry are two manifests to keep
correct — if the split you want is in navigation rather than in curation, use `nav`
groups in `ui-hints.json` instead.

### 3.2 Declaring a role, end to end

Take `Shopper`. It appears in four files, and each one answers a different question.

**Membership** — who holds the role. Locally, `.reventless/users.yaml`, loaded at
startup relative to the process cwd (restart after editing); on AWS these are
Cognito groups.

```yaml
- username: shopper
  password: shopper
  groups: [Shopper]
  userId: local-shopper

# Holds two roles on purpose — this is the account where the role switch has
# something to show.
- username: fulfil
  password: fulfil
  groups: [Fulfilment, Shopper]
  userId: local-fulfil
```

**Permission** — what the role may call. A command with no `@authorize` defaults to
`AllowAuthenticated`, so `PlaceOrder` is open to any logged-in caller and no
`Shopper` gate is needed; `ShipOrder` names its groups and a shopper is refused by
the API:

```rescript
// Ordering/Order/StateChangeSlice/ShipOrder.res — operator-only
@authorize(AllowGroups(["Admin", "Fulfilment"])) ShipOrder({orderId: string})

// Ordering/Customer/ReadModelStream/Customers.res — file-level, whole view
@@reventless.authorize(AllowGroups(["Admin", "Fulfilment"]))
```

Note the two forms: `@authorize` on a **command variant** gates that one command;
`@@reventless.authorize` at **file level** gates the whole component.

**Scope** — whose rows the role reads. `Shopper` is absent from `elevatedGroups`,
so the `@owner` field narrows every read to the caller's own orders:

```rescript
// Ordering/Order/StateViewSliceStream/Orders.res
@owner customerId: string,
```

**Menu** — what the role sees. `Shopper` declares no journey at all, so it gets the
default one; only the operator roles need their own:

```rescript
components: [                                  // ← what Shopper gets
  {plugin: "Catalog", views: ["Products", "Categories"], commands: [], derived: []},
  {plugin: "Ordering", views: ["Orders"],
   commands: ["PlaceOrder", "CancelOrder"], derived: []},
],
journeys: [
  {group: "Merchandiser", components: [ … ]},
  {group: "Fulfilment", components: [
    {plugin: "Ordering", views: ["Orders"],
     commands: ["ShipOrder", "CancelOrder"], derived: ["lifecycles", "canvas"]},
  ]},
],
```

`derived` is where the two audiences differ most sharply for the least text.
`Orders` carries a status and the commands that move it, and its delivery windows
are dates, so the shell can build a lifecycle diagram and a calendar of the same
rows. To `fulfil` that is a picture of the job. To a customer reading their own
three orders it is a state machine of an order pipeline, in a menu group labelled
`Ordering` — which is exactly the leak a curated storefront is supposed to close.

The result, per role:

| | `shopper` | `merch` | `fulfil` | `admin` |
|---|---|---|---|---|
| Menu | storefront (default) | `Merchandiser` journey | `Fulfilment` journey | default + admin API |
| `Orders` menu label | "My Orders" (scoped) | not in menu | "All Orders" (elevated) | "All Orders" (elevated) |
| `Ordering/Orders` | own rows only | not in menu | **every** row | every row |
| `Catalog/Products` | browse | browse + edit | not in menu | everything |
| `Catalog/ProductDemand` | refused by the API | readable | refused by the API | readable |
| `Ordering/Customers` | refused by the API | refused by the API | readable | readable |
| `PlaceOrder` | ✅ own | ✅ own | ✅ own | ✅ |
| `ShipOrder` | ❌ refused | ❌ refused | ✅ | ✅ |
| `AddProduct` | ❌ refused | ✅ | ❌ refused | ✅ |
| Derived pages | none | none | Lifecycles, Calendar | every kind |

Read the `ProductDemand` and `Customers` rows together: `merch` and `fulfil` are
each refused one of them. That is `@@reventless.authorize` doing the work, not the
journey — dropping a view from a journey removes it from a menu and leaves it just
as callable.

**One row, two roles.** The `fulfil` account demonstrates the whole model at once.
Acting as `Fulfilment` it reads every customer's orders — elevation exempts it from
owner scoping — and `ShipOrder` appears on rows whose status is `Placed`. Acting as
`Shopper`, the same account, the same login, reads only its own orders and the API
refuses `ShipOrder` outright.

**A note on `@allowedStates`.** `CancelOrder` carries
`@allowedStates([Orders.Placed])`, which is a **menu filter**: the command is
offered only on rows whose lifecycle field is `Placed`. It is UX, not a gate — the
behaviour is what refuses a shipped order, by returning `OrderAlreadyShipped`.

### 3.3 Acting as one role

A caller holding several groups can act as one of them, from the shell's user
menu. While they do, they *are* that role everywhere: the menu shows that
journey, the data narrows to what the role may read, and the server refuses what
it may not call. Nothing in your app has to know the feature exists.

What this means for how you declare roles:

- A role the caller does not hold is **refused**, never widened into.
- Group names match **exactly** — `shopper` is not `Shopper`.
- Switching back to full membership is not an escalation; it is the membership
  the user already had.

The account to test with is one holding two roles — the hybrid shop's `fulfil`
(`Fulfilment` + `Shopper`) is built for exactly this: acting as `Fulfilment` it
works every customer's orders, and acting as `Shopper` it sees only its own and is
refused `ShipOrder`.

Dev credentials ship in `users.example.yaml`, which `pnpm run setup` copies to the
gitignored `.reventless/users.yaml`. They are throwaway — never reuse them
anywhere real.

---

## 4. Layer 3 — UI hints

`ui-hints.json` carries presentation: what a view is called, where it sits in the
nav, and which cross-plugin actions a row offers. The hybrid shop's file:

```json
{
  "Catalog": {
    "views": {
      "Products": {
        "nav": { "group": "Shop", "order": 0 },
        "rowActions": [
          {
            "label": "Order",
            "pluginId": "Ordering",
            "slice": "PlaceOrder",
            "command": "PlaceOrder",
            "field": "productIds",
            "then": "/Ordering/Orders"
          }
        ]
      },
      "Categories": { "nav": { "group": "Shop", "order": 10 } },
      "ProductDemand": { "nav": { "label": "Demand", "group": "Merchandising", "order": 30 } }
    }
  },
  "Ordering": {
    "views": {
      "Orders": {
        "nav": {
          "label": "All Orders", "scopedLabel": "My Orders",
          "group": "Shop", "order": 20
        }
      }
    }
  }
}
```

The structure is keyed *plugin → views → view*. A `nav` entry sets the menu label,
its group and its sort order. A `rowActions` entry turns a row into the start of a
command in another plugin: the row's key is carried into the named command's
`field`, and `then` is where the user lands afterwards.

**`scopedLabel` is the one key that varies per caller.** A menu label is normally
a fact about the component, and one file can state it for everybody. "My Orders"
is not: it is a claim about *whose* rows, and the same view answers that
differently for a customer and for the agent working the board.

So `label` is what the entry is called when the caller reads every row, and
`scopedLabel` when they are narrowed to their own. It applies only where the view
declares an `@owner` field and the caller is not elevated (§5.3) — a `scopedLabel`
on a view nothing narrows is reported as a hint that can never appear. Leave it
out and `label` is used for everyone.

Write it against the *scope*, not against a role. That way it stays right when you
elevate another group later, instead of needing every role to restate it.

**A view with no `nav` entry keeps the plugin's name as its group.** That is the
usual way a plugin name turns up in a shop's menu — `ProductDemand` above is in
the file for no other reason. When you curate a view into a journey, it is worth
naming where it sits, or the role working it gets a menu group named after your
plugin.

**A `nav` entry cannot speak for a derived page.** A dashboard or a lifecycle
diagram belongs to no single view, so no key here names one. Whether an audience
gets those is curation, and it belongs in the manifest (§3); this file only
decides how what they get is presented.

The key vocabulary belongs to the host shell package
(`@reventlessdev/reventless-host-shell`) and is versioned with it, so this guide
does not enumerate it. The shell drops entries it cannot read, with a warning,
rather than refusing to start. Two mistakes fail the build instead of going
quiet: a `uiHintsFile` path that does not resolve, and content that is not JSON.

**Locally, saving the file updates the running app.** No restart, no reload — the
menu restacks where it stands, so you can name and reorder things by editing and
saving. On AWS the hints are written once at deploy, as they should be: a running
deployment does not follow anybody's working copy. See
[the Local provider guide](/infrastructure/local/).

**Resolve the path from the declaring module**, not from the working directory,
which differs per platform and would make one declaration two different files:

```rescript
let uiHintsFile = NodePath.resolve([NodeImportMeta.dirname, "../ui-hints.json"])
```

---

## 5. Layer 4 — deployment choices

`~hostUiBundle` is where a platform root declares the shell it hosts. Both the
local and the AWS root take the same record; fields marked *AWS* are ignored by the
in-memory platform, which has no deploy step to hang them off.

| Field | Effect |
|---|---|
| `bakedManifest` | the curated manifest of §3 |
| `uiHintsFile` | the hints file of §4 |
| `shellConfig` | shell-owned `config.json` keys (see §5.2) |
| `viewModes` *(AWS)* | optional view modes the shell loads at boot |
| `geocoderPlaceIndex` *(AWS)* | provisions a `Query.geocode` resolver for address search |
| `uploadBucket` *(AWS)* | provisions a presign service and serves the store from the UI's origin |
| `assetsDir` *(AWS)* | a non-default shell bundle; defaults to the resolved host-shell dist |
| `bundleVersion` *(AWS)* | defaults to the `~version` passed to `deployPlatform` |

### 5.1 View modes

```rescript
viewModes: [Map({})],          // built-in demo tiles
viewModes: [Map({style: "…"})] // a real style URL — an account and a bill
viewModes: [Graph({})]         // optional graph layout: Graph({layout: "…"})
```

Each mode is a separately imported chunk, so a deployment that names none downloads
none. `Map` turns on **both** halves of the map feature: the map view mode and the
map-backed geo-point command input are registered together. Naming `Map` without
provisioning `geocoderPlaceIndex` gives you a map that cannot search for an
address; provisioning the index without naming `Map` gives you a capability no
browser reaches.

`viewModes` takes typed constructors rather than strings, so a misspelled mode name
is a compile error instead of an app quietly missing the feature.

### 5.2 `shellConfig`

A `dict<JSON.t>` passthrough for keys the shell owns and the framework has no
opinion about — so the shell can add a knob without waiting on a core release.

```rescript
shellConfig: Dict.fromArray([
  ("appName", JSON.Encode.string("Online Shop")),
  ("home", JSON.Encode.string("/Catalog/Products")),
  ("elevatedGroups", ["Admin", "Fulfilment"]->Array.map(JSON.Encode.string)->JSON.Encode.array),
]),
```

It merges in **under** the keys the deploy computes (`apiEndpoint`, `region`,
`authMode`, `cognitoUserPoolId`, …). A key colliding with a computed one **fails
the deploy naming the key**, rather than quietly pointing the app at a different
API. See [the `config.json` contract](/infrastructure/ui-fragments-deployment) for
the full computed set.

`home` is per-deployment rather than a nav hint, because an app has one home and no
view is entitled to claim it.

### 5.3 Elevated groups

`elevatedGroups` appears twice on purpose, and the two are different things:

```rescript
// The server-side rule: these groups read across owners.
Reventless.OwnerScope.setElevatedGroups(Storefront.elevatedGroups)

// The browser's mirror of it.
shellConfig: Dict.fromArray([("elevatedGroups", …)])
```

The server call decides whose rows a query returns. The `shellConfig` key is the
browser's mirror of the same fact: it decides whether the generated form asks for
the owner field or fills it in, whether an owner column is worth showing, and
which label `scopedLabel` picks (§4). Read both from **one declaration** — a
mirror that disagrees with the server is the failure this key exists to avoid.
Omit it and the shell assumes nothing is scoped.

The declaration answers **exactly one question** — who reads past the narrowing
the framework applies to ordinary callers. That covers both rules that narrow a
read: `@owner`, whose rows a query returns (§2.10), and `@retired`, who may ask
for the archive with `includeRetired` (§2.11). One list for both, deliberately —
two would eventually disagree about who an operator is, and the gap would surface
one view at a time.

It must not be read as naming operators. A group listed here is not thereby an
administrator, gets no admin API, and gets no journey: an elevated role with a
curated surface of its own declares it under `journeys` like any other.

Set the elevated groups **before** the plugins are built — the components read
them as they are constructed.

---

## 6. Putting it together

The hybrid shop's local root, in full:

```rescript
module Platform = ReventlessLocal.Platform.Make()

Reventless.OwnerScope.setElevatedGroups(OnlineShopHybridSeed.Storefront.elevatedGroups)

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
  ~hostUiBundle={
    bakedManifest: OnlineShopHybridSeed.Storefront.manifest,
    uiHintsFile: OnlineShopHybridSeed.Storefront.uiHintsFile,
    shellConfig: Dict.fromArray([
      ("appName", JSON.Encode.string("Online Shop")),
      ("home", JSON.Encode.string("/Catalog/Products")),
      (
        "elevatedGroups",
        OnlineShopHybridSeed.Storefront.elevatedGroups
        ->Array.map(JSON.Encode.string)
        ->JSON.Encode.array,
      ),
    ]),
  },
)

Platform.startServers()
```

The AWS root differs only in the fields a deploy can honour — `viewModes`,
`geocoderPlaceIndex`, and the capabilities it provisions. Everything about *the
shop* comes from the same shared module, so the two cannot disagree about what the
shop is.

What each of the shop's components declares:

| Component | Declarations |
|---|---|
| `Catalog/Products` | `Money.t` price; `@storageRef("productImages")` image; `@index categoryId`, so a category's products can be asked for by category; nav group "Shop"; a row action that starts `Ordering.PlaceOrder` |
| `Catalog/Categories` | `@storageRef("categoryImages")` image — its own store, not the products' one; nav group "Shop" |
| `Catalog/ProductDemand` | `@@reventless.authorize(AllowGroups(["Admin", "Merchandiser"]))`; `@id productId`; only in the `Merchandiser` journey, under its own nav group |
| `Ordering/Orders` | `@owner customerId`; `lifecycle` by name; `DateTime` timestamps; `DateRange` delivery window; nav "All Orders", or "My Orders" for a caller reading only their own |
| `Ordering/Customers` | `@@reventless.authorize`; `@displayName email`; `@lifecycle accountStatus` with `@retired Deactivated` on its own constructor; `@hidden locationNote`; `GeoPoint` location, beside an unannotated `locationStatus` that is a job's progress rather than a lifecycle |
| `Ordering/AvailableProducts` | `@@reventless.visibility(Internal)` — reachable only as the `@ref` target of `PlaceOrder`'s product picker |
| `Ordering/PlaceOrder` | `@owner customerId`; `@ref("AvailableProducts") productIds`; optional `DateRange` delivery window |

Note `AvailableProducts`: it is in no journey, yet it still reaches the shell,
because `PlaceOrder` `@ref`s it. It rides along as a reference target for the
product picker while staying out of every menu — curation and capability answering
independently, which is the pattern the four layers exist to allow.

---

## 7. Related

- [Reventless PPX Guide](./reventless-ppx.md) — full annotation reference
- [Generated GraphQL API Guide](./graphql-api-guide.md) — what filters and
  orderings the annotations generate
- [Read Model](./components/readmodel.md) — visibility and live updates in context
- [UI Fragments Deployment](/infrastructure/ui-fragments-deployment) — the
  `config.json` contract and what the platform stack provisions
- [Identity](./common-modules/identity.md) — the authorization that these hints are
  deliberately not
