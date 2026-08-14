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
│  @status, @displayName, @hidden, @metric, semantic types …           │
│  → x-reventless-* properties on the generated JSON Schema            │
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

Field annotations on a `@schema type state` record are collected by the PPX into
sury metadata, and `SuryToJsonSchema.deriveObjectSchema` stamps them onto the read
model's JSON Schema as `x-reventless-*` extension properties. None of them changes
the projection or the stored data — they are declarations *about* the data that
travel with it.

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

When no annotation is present the framework guesses, and publishes which rung of
the ladder it used as `queryableDef.labelFieldSource`:

| Rung | Source | How the label was chosen |
|---|---|---|
| 1 | `annotation` | a `@displayName` spec — the author said so |
| 2 | `convention` | a field named `name`, `title`, `label` or `displayName` (case-insensitive, exact) |
| 3 | `position` | the first label-shaped field in declaration order |
| 4 | `fallback` | nothing suitable — falls back to `id`, with a logged warning |

Rung 3 is worth avoiding deliberately: a state gains a new name whenever a field is
inserted above the old one. Adding a `placedAt` field so date views have something
to key off would rename every order to a timestamp.

### 2.2 Lifecycle status

**`@status`** marks the field holding the entity's lifecycle state. The generated
view sections and badges rows by it, and it drives the per-row command menu — each
command's `@allowedStates` is filtered against the row's current status.

```rescript
@schema type status = Placed | Shipped | Cancelled

@schema
type state = {
  orderId: string,
  @status status: status,
}
```

Resolution order: (1) the annotated field; (2) a field literally named `status`
whose shape is an enum; (3) none, and the per-row filter is inert. At most one
`@status` per record — a duplicate is a compile error.

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

**`@semantic("id")`** is the annotation tier for a field whose type carries no
semantic. The id vocabulary belongs to the UI, so the PPX cannot validate it. A
type-carried semantic always wins over an annotation, and a disagreement between
the two is logged rather than silently resolved.

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

**`@@reventless.visibility(Internal)`** hides a read model or state-view slice from
the generated UI's manifest — panels and pages. GraphQL exposure, authorization,
resolver provisioning and `pluginStructure.queryableDef` are all unaffected: this
is a UX hint, not a boundary. Use it for denormalised mirrors that exist as lookup
targets rather than as surfaces.

**`@live(true | false)`** goes on the `@schema type state` declaration itself, not
on a field. `false` marks an investigative or historical view where a Live control
makes no sense; `true` marks an operational one. Absent means the consumer's own
default applies.

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

### 2.11 The wire format

Everything above surfaces on the component's JSON Schema:

```json
{
  "type": "object",
  "x-reventless-visibility": "Internal",
  "x-reventless-live": false,
  "properties": {
    "productId":  { "type": "string", "x-reventless-id": true },
    "status":     { "type": "string", "enum": ["Placed"], "x-reventless-group-by": true },
    "note":       { "type": "string", "x-reventless-hidden": true },
    "orderCount": { "type": "integer", "x-reventless-metric": { "aggregate": "sum" } },
    "price":      { "type": "object", "x-reventless-semantic": "money",
                    "x-reventless-semantic-source": "type" },
    "customerId": { "type": "string", "x-reventless-owner": true }
  }
}
```

`x-reventless-semantic-source` is the discriminator that lets a reader rank a
type-carried semantic above an annotated one.

---

## 3. Layer 2 — the baked manifest

A shell needs to know which components exist for its audience. By default it asks
the admin-gated component-definitions API. A **baked manifest** replaces that call
with a static JSON file written at deploy time, which is what lets a shop serve
customers who have no admin API to open.

The deployment declares **what to include**, never what to write — the content is
derived from the registered plugins' structures, which only the framework knows.

```rescript
let manifest: ReventlessInfra.Platform.bakedManifest = {
  components: [
    {plugin: "Catalog", views: ["Products", "Categories"], commands: []},
    {plugin: "Ordering", views: ["Orders"], commands: ["PlaceOrder", "CancelOrder"]},
  ],
  journeys: [
    {
      group: "Merchandiser",
      components: [
        {plugin: "Catalog",
         views: ["Products", "Categories", "ProductDemand"],
         commands: ["AddProduct", "ChangeProductPrice", "AddCategory", "RenameCategory"]},
      ],
    },
    {
      group: "Fulfilment",
      components: [
        {plugin: "Ordering", views: ["Orders"], commands: ["ShipOrder", "CancelOrder"]},
      ],
    },
  ],
}
```

**Selection semantics.** `views` / `commands` unset means every public component of
that kind; set means exactly the named ones. It is an include-list rather than an
exclude-list, so a component added later has to be opted in and cannot silently
widen a curated surface. A name that matches nothing **fails the deploy naming
it** — a silent no-op here produces a missing page no log explains.

**Journeys** are per-audience surfaces beside the default one. `group` is the
caller group the journey serves; the shell picks by the role the caller is acting
as. `label` names it in a switcher, defaulting to the group's own name; `key` names
the file, defaulting to a per-group name derived from the group (lower-cased,
non-alphanumerics folded to `-`, e.g. `component-manifest-fulfilment.json`).

Every file is curated before any is written, so a declaration naming a missing
component fails the boot rather than leaving one audience's file beside a stale
copy of another's.

**`components` is the default journey** — what a caller matching no declared
journey gets. It is not only backward compatibility: a local dev session without a
login carries a group no deployment declares, so without a default it would match
nothing and render an empty shell.

:::caution Journeys are a local-platform feature today
The in-memory platform writes one manifest file per journey and publishes the map
as `journeyManifestUrls` in `config.json`. **The AWS deploy still writes only the
default manifest** — a `journeys` declaration is carried in the type and ignored
by the deploy. Declare journeys for local development by all means; do not rely on
them to shape a deployed app's menu yet.
:::

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
  {plugin: "Catalog", views: ["Products", "Categories"], commands: []},
  {plugin: "Ordering", views: ["Orders"], commands: ["PlaceOrder", "CancelOrder"]},
],
journeys: [
  {group: "Merchandiser", components: [ … ]},
  {group: "Fulfilment", components: [
    {plugin: "Ordering", views: ["Orders"], commands: ["ShipOrder", "CancelOrder"]},
  ]},
],
```

The result, per role:

| | `shopper` | `merch` | `fulfil` | `admin` |
|---|---|---|---|---|
| Menu | storefront (default) | `Merchandiser` journey | `Fulfilment` journey | default + admin API |
| `Ordering/Orders` | own rows only | not in menu | **every** row | every row |
| `Catalog/Products` | browse | browse + edit | not in menu | everything |
| `Catalog/ProductDemand` | refused by the API | readable | refused by the API | readable |
| `Ordering/Customers` | refused by the API | refused by the API | readable | readable |
| `PlaceOrder` | ✅ own | ✅ own | ✅ own | ✅ |
| `ShipOrder` | ❌ refused | ❌ refused | ✅ | ✅ |
| `AddProduct` | ❌ refused | ✅ | ❌ refused | ✅ |

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
offered only on rows whose `@status` field is `Placed`. It is UX, not a gate — the
behaviour is what refuses a shipped order, by returning `OrderAlreadyShipped`.

### 3.3 Acting as one role

A caller holding several groups can narrow their token to one of them. The narrowed
token carries the `activeRole` claim, and its group set is exactly that one role —
so every enforcement point sees the narrowed membership without knowing the feature
exists.

- A role the caller does not hold is **refused**, never widened into.
- Group names match **exactly** — `shopper` is not `Shopper`.
- Narrowing with no role requested mints full membership, exactly as before.
- The roles given up are published as an `availableRoles` claim **for offering the
  switch back only**. It is by definition wider than what the caller currently
  holds; never read it for authorization.

Locally, `POST /__inmemory/switch-role` re-mints an existing session without asking
for the password again — membership is re-read from the user store rather than from
the current token, because a narrowed token carries one group and judging membership
by it would make the switch one-way.

Both endpoints answer with the same `{token, identity}` shape, so a switch is
indistinguishable from a fresh session downstream and a client stores the result the
same way. The default port is 4000 (`REVENTLESS_DOMAIN_PORT`).

```bash
# Log in as the two-role account (or use the host shell's LoginPage).
curl -sX POST localhost:4000/__inmemory/login \
  -d '{"username":"fulfil","password":"fulfil"}'
# → identity.groups: ["Fulfilment", "Shopper"]

# Act as Shopper: Ordering/Orders now returns only this account's own orders,
# and ShipOrder is refused.
curl -sX POST localhost:4000/__inmemory/switch-role \
  -H "Authorization: Bearer $TOKEN" -d '{"activeRole":"Shopper"}'
# → identity.groups: ["Shopper"], claims.activeRole: "Shopper",
#   claims.availableRoles: "Fulfilment,Shopper"

# Switch back — widening to full membership is not an escalation; it is the
# membership the user store already holds.
curl -sX POST localhost:4000/__inmemory/switch-role \
  -H "Authorization: Bearer $TOKEN" -d '{}'

# Refused: this account does not hold Admin.
curl -sX POST localhost:4000/__inmemory/switch-role \
  -H "Authorization: Bearer $TOKEN" -d '{"activeRole":"Admin"}'
# → Cannot act as "Admin": not a group this user holds
```

`/__inmemory/login` accepts an `activeRole` too, so a client can land in a chosen
role without a second round trip.

The credentials above ship in `users.example.yaml`, which `pnpm run setup` copies to
the gitignored `.reventless/users.yaml`. They are throwaway dev credentials — never
reuse them anywhere real.

:::caution Deploy verification pending
The local path is built and verified. The AWS path — a role-state table, a
pre-token-generation trigger, and a `Platform_SetActiveRole` write door — is built
and unit-tested but has **not yet met a live user pool**.
:::

---

## 4. Layer 3 — UI hints

`ui-hints.json` carries presentation: what a view is called, where it sits in the
nav, and which cross-plugin actions a row offers. The hybrid shop's file:

```json
{
  "Catalog": {
    "views": {
      "Products": {
        "nav": { "label": "Shop", "group": "Shop", "order": 0 },
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
      "Categories": { "nav": { "group": "Shop", "order": 20 } }
    }
  },
  "Ordering": {
    "views": { "Orders": { "nav": { "label": "My Orders", "group": "Shop", "order": 10 } } }
  }
}
```

The structure is keyed *plugin → views → view*. A `nav` entry sets the menu label,
its group and its sort order. A `rowActions` entry turns a row into the start of a
command in another plugin: the row's key is carried into the named command's
`field`, and `then` is where the user lands afterwards.

**The framework treats this file as opaque bytes.** It resolves the path, checks
that the content parses as JSON, and writes it verbatim — on AWS as an object
beside `config.json`, locally into the served bundle. The key vocabulary belongs to
the host shell package (`@reventlessdev/reventless-host-shell`) and is versioned
with it, so this guide does not enumerate it; the shell validates what it reads and
drops malformed entries with a warning rather than failing to boot.

Two failure modes are worth knowing, because both produce "hints that quietly do
nothing" and both are therefore made loud instead:

- a `uiHintsFile` path that does not resolve fails the build naming the path;
- content that is not JSON fails the same way.

**Local behaviour.** The host shell package ships its own demonstration
`ui-hints.json` as a dev-mode fallback. A declared file wins, and the shipped one is
preserved as `ui-hints.base.json` so that withdrawing the declaration restores the
original rather than leaving yesterday's hints in place with nothing in the diff to
explain them. The AWS deploy excludes the package's own file entirely — a deployed
app with nothing declared has no curated nav at all, rather than someone else's.

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

`viewModes` is a closed variant rather than a list of strings on purpose: a
misspelled mode name would type-check, deploy, and yield an app with the feature
silently absent.

### 5.2 `shellConfig`

An untyped `dict<JSON.t>` passthrough for keys the shell owns and the framework has
no opinion about. It is untyped deliberately — re-declaring the shell's schema here
would mean a lockstep core release every time the UI adds a knob.

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

The server call decides what an owner-scoped resolver returns. The `shellConfig`
key is the browser's mirror: it decides whether the generated form asks for the
owner field or supplies it, and whether an owner column is worth a column. Read
both from **one declaration** — a mirror that disagrees with the server is exactly
the failure the key exists to avoid. The shell treats an absent key as "unknown",
so omitting it silently stops hiding anything.

Set the elevated groups **before** the plugins are built: component construction is
where the owner-scoped resolvers read them.

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
| `Catalog/Products` | `Money.t` price; `@storageRef("productImages")` image; nav label "Shop"; a row action that starts `Ordering.PlaceOrder` |
| `Catalog/Categories` | nav group "Shop", order 20 |
| `Catalog/ProductDemand` | `@@reventless.authorize(AllowGroups(["Admin", "Merchandiser"]))`; `@id productId`; only in the `Merchandiser` journey |
| `Ordering/Orders` | `@owner customerId`; `@status status`; `DateTime` timestamps; `DateRange` delivery window; nav label "My Orders" |
| `Ordering/Customers` | `@@reventless.authorize`; `@displayName email`; `@status locationStatus`; `@hidden locationNote`; `GeoPoint` location |
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
