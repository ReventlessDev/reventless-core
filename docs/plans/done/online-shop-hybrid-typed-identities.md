# Plan: the hybrid example types its ids

**Status:** Done (2026-09-21).<br/>
**Follows:** [entity-id-types-per-identity.md](entity-id-types-per-identity.md), which
migrated the aggregates and DCB examples and stopped there. The design and the churn record are
in the [analysis](../../analysis/entity-id-types-per-identity.md).<br/>
**Touches:** `examples/online-shop-hybrid` (catalog, catalog-spec, ordering, seed-data,
platform-local), `traits/attachments` (emitter), `scripts/check-trait-pack.mjs`, and
`reventless-core`'s `Plugin_Structure` (see Phase 3).

## In plain words

The other two online shops now give every entity's id its own type: a `ProductId.t` cannot be
passed where an `OrderId.t` is expected, and the compiler says so. The hybrid shop still uses
plain `string` for all of them, about 230 id fields in `src/` alone. This plan retypes those
ids, one plugin at a time, without changing anything on the wire. Stored events, DCB tags and
the GraphQL schema all stay the same.

The hybrid shop is harder than the other two for three reasons:

- **Traits write part of its code.** `ProductImages` and `CategoryImages` come from the
  attachments trait, `GeocodeCustomerAddress` from address-geocoding, and the notification
  slices from the notification trait. What those emitters write has to stay what the host
  holds.
- **It is deployed.** Every alpha push deploys it, so a change to a tag key would strand
  stored events.
- **It ships seed data and an AutoUI.** A derived reference is a visible change: a
  field becomes a dropdown.

## Hard constraints

- **No wire change.** Every retyped field's name equals its identity's key (`productId` →
  `ProductId`, key `productId`), so tags do not move. `schema/dcb-scope.json` and
  `schema/domain-api.graphql` must not change. If one does, stop and find out why. Do not
  refresh the golden to make the check pass.
- **Names that are not identities stay strings.** `recipientId`, `sourceId`, `ruleId`,
  `callerId` and `ownerId` stay `string` (see *Left as strings*). Retyping `recipientId`
  as `CustomerId.t` would move its tag key from `recipientId` to `customerId`, which is the
  analysis's open question 4 and needs `@dcbTag("recipientId")` or a data migration.
- **The identity check decides the order.** `IdentityCheck` reads every StateChange slice
  in a plugin, and reports an untyped `productId: string` once any slice types a
  `ProductId.t`. `check:dcb-scope` fails on that report. So all of a plugin's slices, including
  the trait-emitted ones, move together.

## Identities

| Identity | Declared in | Used by |
|---|---|---|
| `ProductId` | `catalog-spec` (already depends on `reventless-spec`; the PPX already skips its `module Id`) | catalog, ordering's `CatalogProduct` chapter, `SyncCatalogProduct`, `AvailableProducts`, `PlaceOrder` / `Orders` `productIds` |
| `CategoryId` | `catalog/src/Category/CategoryId.res` | catalog |
| `OrderId` | `ordering/src/Order/OrderId.res` | ordering |
| `CustomerId` | `ordering/src/Customer/CustomerId.res` (`Customer` exists, `CustomerId` does not) | ordering; the `Customer` aggregate and the `Customers` read model take `module Id = CustomerId` |

### Left as strings, deliberately

- **Catalog's `orderId`** (`RecordProductDemand`, `ProductDemand`). Catalog cannot see
  ordering's identity, as in the other two examples.
- **The `ordering-spec` contract** (`ItemOrdered`, `ItemOrderCancelled`, the telemetry
  directives). Typing it would mean `ordering-spec` declaring `OrderId` and `CustomerId`.
  Catalog is the one consumer and already keeps `orderId` a string, so nothing gains a type.
  This matches the other examples.
- **The notification trait's vocabulary** (`recipientId`, `sourceId`, `ruleId`). A recipient
  is any principal and a source is any entity, so binding them to `CustomerId` / `OrderId`
  would bind the trait to one host. `NotificationIntake` is the seam: it hands
  `customerId` / `orderId` in as `recipientId` / `sourceId` and converts there with `toString`.
- **The outbound `collect`'s `~sourceId`.** `OutboundTranslationSlice.collect` takes
  `~sourceId: string` in the framework, so `GeocodeCustomerAddress` and
  `AnnounceRecipientContact` keep string items. Typing that seam is framework work and out of
  scope here.
- **Seed-side ids read back from GraphQL** (`ShopSnapshot`, `callerId`, `ownerId`). They are
  transport values, not domain fields.

---

## Phase 1: the attachments emitter writes an identity

`ProductImages` and `CategoryImages` are StateChange slices, so the identity check sees them.
Hand-typing the committed files would pass every check, because `check-trait-pack` builds a fresh
emit and never diffs it against the specimen. But then the specimen would no longer be what
the trait writes, which is the point of a specimen.

- `Attachments_Scaffold`: an optional `entityIdType` config (e.g. `ProductId`). When given,
  the emitted `<entityId>` fields are `<entityIdType>.t` and any string routing converts with
  `toString`. When absent, output is byte-identical to today's.
- `check-trait-pack.mjs`: the attachments specimens pass it, so the fresh emit in the
  scratch host is typed. That also proves a typed emit compiles and conforms.
- Address-geocoding: check whether its emitted `GeocodeCustomerAddress` still builds against a
  `Customer` whose `Id` is `CustomerId`. It should, because `collect` gets a string `~sourceId`
  and `outboundItem` is not a slice schema. If so, it needs no change. Record the result.

**Validation.** Attachments conformance suites green with and without the option;
`pnpm run check:traits` green.

**Done.** `check-trait-pack` gained a `declare` step, so the `Gadget` specimen declares a
`GadgetId` in the scratch host and is emitted typed, while `Badge` stays a string: both
branches compile and conform. The geocoding emitter needed nothing, as expected: its
emitted translation builds against the typed `Customer`.

## Phase 2: catalog and catalog-spec

- `catalog-spec`: declare `ProductId`; `Products_ExtensionPoint` events carry `ProductId.t`.
- `catalog`: declare `CategoryId`; retype every Product and Category slice, `ImportProduct`,
  the two views (`Products`, `Categories`) with `module Key = …`, and the attachments slices
  through the Phase 1 option. `AddProduct` drops `@ref("Categories")` if the derived reference
  resolves the same view.
- `ordering`: only what the typed contract forces, i.e. `Products_Extension` converts at the
  routing seam. Its own fields are Phase 3.
- Catalog GWT tests: typed literals made once per file (`let pid = ProductId.make("p-1")`).

**Done, together with Phase 3.** Nothing was committed between them, so ordering's
extension took the typed contract directly instead of through a `toString` that Phase 3
would have removed.

**Validation.** Catalog and ordering build with zero warnings; GWT suites green;
`check:dcb-scope`, `check:graphql` and `check:lifecycle` report no drift. The lifecycle
sidecar reads `pid("p-1")` since the DCB migration's `SidecarEmit` fix, but a moved
from-set means that fix missed a case. `check:traits` green.

## Phase 3: ordering

- Declare `OrderId`, `CustomerId`. Retype the Order, Customer and CatalogProduct chapters
  (`CatalogSpec.ProductId`), `EmailVerificationChallenges`, `AutoShipOrder`, the `Orders` /
  `AvailableProducts` views (`module Key`), and `Customer` / `Customers` (`module Id`).
  `Customers_Projections` loses its `id->Customer.Id.toString` for the key.
- `Orders.customerId` is `@owner`. `@owner` accepts an identity since the PPX change;
  confirm the derived `_owner` GSI definition is unchanged.
- `PlaceOrder` drops `@ref("AvailableProducts")` if the derived reference names the same view.
- `Orders_ExtensionPointMapping` converts into the untyped `ordering-spec` contract.
- Ordering GWT tests, including the flow tests that span both plugins.

**Validation.** As Phase 2, plus the set of derived references matches the table above.
Every new reference (a field that was not `@ref` before) is a new AutoUI dropdown. List
them in the commit and look at each one in the local AutoUI.

**Done.** `PlaceOrder` keeps its `@ref`: the line item's `productId` is nested, and a
reference is derived only on a top-level field. The reference set was read off
`Platform_PluginStructures` on a running local platform and checked against AutoUI's
resolver rather than in the browser. That check found the one real regression: AutoUI
takes a command's references in place of its heuristic, and only the heuristic knew that a
Collection command's own id is minted. `AddCategory`, `PlaceOrder` and `SubmitEmailProof`
would have shown a list of existing rows for the id they create. `Plugin_Structure` now
derives no reference for a Collection command's `aggregateIdField` (`IdentityReferenceTest`).
After the fix the only new dropdown on a create form is `PlaceOrder.customerId`, an
`@owner` field the resolver overwrites for ordinary callers. The `@owner` GSI is
unchanged: the SDL golden did not move.

## Phase 4: seed data, docs, churn

- `seed-data`: `DemoCommands` / `HybridSeedData` build typed commands. Convert once, where
  `DemoData`'s string ids enter a command. `DemoData` stays string because it is authored data.
- The example's README: one paragraph on identities, pointing at the aggregates example's
  explanation rather than repeating it.
- Record the churn in the analysis (§ Churn), in the same form as the aggregates entry: files,
  conversions and where they sit, test literals, and anything left as a string.
- `git mv` this plan to `done/`.

**Validation.** `pnpm run build` zero warnings; `pnpm test`; `pnpm run test:projects`;
the seed-data tests; a local run of `seed:local` against the in-memory and SQLite
backends, then the AutoUI walk from Phase 3. After the alpha push, the deploy is a no-op for
stored data. Check it by placing an order against events written before the change.

**Done.** The `sample` set seeds identically on both backends, and the SQLite store holds
every id as a plain string under the same five tag keys. Replaying events written before
the change is left to the alpha deploy, which reads the stack's existing log.

## Out of scope

- Typing `OutboundTranslationSlice.collect`'s `~sourceId`, and the address-geocoding and
  notification emitters with it.
- A notification-trait identity for recipients, and `ordering-spec` identities.
- The downstream repos' copies of the hybrid shop, if any. They pick this up when they
  take the release, as with the framework phases.
