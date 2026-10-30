# Plan: the online shop example closes its gaps, and runs its whole story locally

**Date:** 2026-10-30<br/>
**Status:** 🚧 [OE1](#oe1-a-category-brought-back-takes-products-again) to [OE3](#oe3-a-plugin-with-no-slices-yet-builds) built 2026-10-30, uncommitted; they ship as the next alpha once committed and pushed. [OE4](#oe4-a-stand-in-geocoder-for-the-local-platform) to [OE7](#oe7-the-examples-readme-says-it) not started.<br/>
**Owns:** two behavior gaps in
[examples/online-shop-hybrid](../../examples/online-shop-hybrid/README.md), a plugin with no
slices yet that fails its build, and a stand-in geocoder for the local platform. It also orders
two pieces other plans own: the contact-verification trait's extraction
([Phase C of trait-contact-verification.md](trait-contact-verification.md#phase-c--extract-writing-the-procedure-down-as-you-go))
and the visitor door on AWS
([DW5](self-registration-is-a-chapter-not-a-trait.md#dw5-a-narrow-door-for-visitors-on-aws) to
[DW8](self-registration-is-a-chapter-not-a-trait.md#dw8-the-admission-check-and-the-shells-configuration-on-aws)
of [self-registration-is-a-chapter-not-a-trait.md](self-registration-is-a-chapter-not-a-trait.md)).

> **Questions and short answers**
>
> 1. *What is wrong with the example?* **Two rules do less than the shop means.** A category that
>    was archived and brought back refuses new products, and any signed-in caller may deactivate
>    any customer ([§1](#1-why)).
> 2. *Why a local geocoder?* **So the example's whole story runs on one machine.** Today every
>    address stays queued locally, so the customers map and the geocoding scenarios never run end
>    to end outside AWS ([OE4](#oe4-a-stand-in-geocoder-for-the-local-platform)).
> 3. *Does the stand-in pretend to geocode?* **No.** It answers only for the addresses a file
>    names, and leaves every other address queued, as today ([OEQ1](#5-open-questions)).
> 4. *What has to be released?* **One core release after
>    [OE1](#oe1-a-category-brought-back-takes-products-again) to
>    [OE3](#oe3-a-plugin-with-no-slices-yet-builds), a second after
>    [OE4](#oe4-a-stand-in-geocoder-for-the-local-platform) and
>    [OE5](#oe5-contact-verification-extracted-as-a-trait)**
>    ([§3](#3-steps)).

**Id prefixes.** The steps are numbered OE1 to OE7 (OE for *online-shop example*); the open
questions OEQ1 and OEQ2 ([§5](#5-open-questions)).

---

## 1. Why

The online shop is the framework's complete example: two plugins that hear each other through
extension points, a registration chapter, three grafted traits, automations on a time. Reading it
rule by rule against what a shop means turns up two places where it does less:

- **A category brought back takes no new products.** `AddProduct` folds `CategoryAdded` and
  `CategoryArchived` into its live categories, but not `CategoryUnarchived`. Archive a category,
  bring it back with `UnarchiveCategory`, and `AddProduct` into it is refused with
  `CategoryNotFound`, although `Categories` lists it again.
- **Any signed-in caller may deactivate any customer.** The `Customer` aggregate's commands carry
  no `@authorize`, and the aggregate has no owner rule, so `Deactivate`, `Reactivate`,
  `UpdateEmail` and `UpdateAddress` are open to every caller for every customer.

Two further things keep the example from running its whole story on one machine:

- **The local platform has no geocoder**, by design (`LocalCapabilities.res`): a place index is an
  account and a bill. `GeocodeCustomerAddress`'s items stay queued, so the `Customers` map shows
  no customer and the trait's flow never completes locally.
- **A plugin with no slices yet fails its build**: `postbuild: emit-capabilities src/` reads
  `pluginStructure`, which the generator leaves out of a plugin with nothing in it. Adding a
  second plugin to an app and building before its first slice exists fails for that reason only.

## 2. Rules every step keeps

1. **The example's behavior changes only where [§1](#1-why) names it**; every other scenario stays as it
   is, and each fix comes with the scenario that failed before it.
2. **The stand-in is opt-in and honest**: without its file, the local platform behaves exactly
   as today.
3. **Steps owned by another plan are done there**; this plan only orders them and checks their
   exit against the example.

## 3. Steps

### OE1: a category brought back takes products again

`AddProduct` consumes `CategoryUnarchived({categoryId})` and puts the id back into
`liveCategoryIds`. A new scenario in `AddProduct_GWT`: added, archived, brought back, product
added: accepted. The model sidecar is regenerated. The `online-shop-dcb` and
`online-shop-aggregates` examples have no way to bring a category back, so the gap is this
example's alone.

**Exit:** the new scenario passes; the existing ones are unchanged. Size S.

**Built 2026-10-30.** `AddProduct` consumes `CategoryUnarchived` and folds it as it folds
`CategoryAdded`. The new scenario failed before the fix (`CategoryNotFound`) and passes now;
the catalog's 214 tests pass. `pnpm run check:lifecycle:update` moved
[lifecycle-model.json](../../examples/online-shop-hybrid/schema/lifecycle-model.json) (the
model sidecars are build outputs and are not tracked); the DCB scope golden is unchanged.

### OE2: who may change a customer

- `Deactivate` and `Reactivate` get `@authorize(AllowRoles([Admin]))`.
- `Register`, `UpdateEmail` and `UpdateAddress`: the customer themself, or an administrator. How
  an aggregate says *the caller is this customer* is [OEQ2](#5-open-questions).
- The seed (`DemoCommands.res`, `DemoFollowUp.res`) signs in as a role that may still do what it
  does; `AuthzProbe` gains the refusals.

**Exit:** a shopper's `Deactivate` is refused by the API; the seed's `full`, `sample` and `next`
runs pass locally. Size S, or M if [OEQ2](#5-open-questions) needs the aggregate to learn an owner.

**Built 2026-10-30, with the owner rule** ([OEQ2](#5-open-questions) took the recommended answer).

- `Deactivate` and `Reactivate` carry `@authorize(AllowRoles([Admin]))`.
- `Customer` declares `module Id = Reventless.Id.Owned(CustomerId)`. `Id.Owned` (spec) marks
  the id's schema with `Owner`; the aggregate handler then checks every command, the creating
  one included, against the aggregate's own id, through the same `OwnerScope.decideActing` the
  event-recorded owner uses. Exempt callers and claimless platform commands pass, as before.
  Unlike an event-recorded owner, snapshots stay on.
- The aggregate GWT harness mirrors it: `onId(id)` names the aggregate a scenario acts on, and
  `Caller.operatorIn([Admin])` is an elevated caller holding roles. `Decision_GWT.AggregateSpec`
  now requires `module Id`; the flow harness's aggregate step takes the new
  `AggregateDeciderSpec`, which does not.
- Tests: 8 new rows in `OwnerActingTest` (42 pass; 3 fail with the check switched off), 12 new
  `Customer_GWT` scenarios (34 pass; 3 fail without `Id.Owned`). Documented in
  [authorization.md](../../packages/doc/docs-app/authorization.md#rows-that-belong-to-a-caller)
  and [given-when-then.md](../../packages/doc/docs-app/given-when-then.md#who-may-act-ascaller-and-thenforbidden).
- `AuthzProbe` probes `Customer_Deactivate` and `Customer_Reactivate`; it compares role rules
  only, so the owner rule is not one of its rows.
- Run against the local platform (memory backend, uploads skipped, signed in as `admin`):
  `full`, `next` and `sample` passed with no refusal, and `authz` matched all 36 pairs, shopper,
  merchandiser and fulfilment refused on both new rows. By hand, a shopper's `UpdateEmail` on
  another customer answered `Forbidden` and on their own was accepted. Not run on AWS.

### OE3: a plugin with no slices yet builds

`emit-capabilities` treats a missing `pluginStructure` as an empty plugin and writes an empty
`capabilities.json`, instead of failing.

**Exit:** a plugin package with only `plugin.json` and an empty `LifecycleModel.res` builds with
its `postbuild` step in place. Size S.

**Already built** on 2026-10-26, before this plan, in `fix(local): emit-capabilities writes an
empty manifest for a plugin with no parts yet`, and released since: `EmitCapabilities` reads
`pluginStructure` as nullable and renders `{"capabilities": []}`, and `EmitCapabilitiesTest`
holds the case. Checked again 2026-10-30: a throwaway package with only `plugin.json` and an
empty `LifecycleModel.res` ran `generate-plugin`, `rescript build` and `emit-capabilities`
and wrote the empty manifest. No change was needed.

**Release:** [OE1](#oe1-a-category-brought-back-takes-products-again) to [OE3](#oe3-a-plugin-with-no-slices-yet-builds) together, as the next alpha.

### OE4: a stand-in geocoder for the local platform

- `LocalCapabilities` reads an optional `.reventless/places.yaml` beside `accounts.yaml`: a list
  of addresses, each with a point. `geocode` answers a listed address with its point and leaves
  every other one `Unavailable`, as today ([OEQ1](#5-open-questions)).
- The example ships `platform-local/places.example.yaml` holding the seed's cities
  (`DemoData.cityCoords`), copied by `setup` as `accounts.yaml` is.
- The local-dev guide gains a section: what the file does, and that nothing else is resolved.

**Exit:** with the file, a seeded customer's address is located on the local platform and the
`Customers` map shows them; without it, the platform logs the same line as today and nothing else
changes. Size M.

### OE5: contact verification extracted as a trait

Owned by [Phase C of trait-contact-verification.md](trait-contact-verification.md#phase-c--extract-writing-the-procedure-down-as-you-go).
Both consumers exist now: the email change on `Customer` and the registration chapter
([Phase B](trait-contact-verification.md#phase-b--the-second-consumer)). The extraction moves
`ContactVerification.res` and its guards out of the example into `traits/contact-verification`,
grafts it back into `Customer` with its conformance suite bound, and writes the extraction
procedure down as that plan requires.

**Exit:** that plan's own; here, the example's `Customer` names the trait in `let traits`, and its
tests are the same count, green. Size L (that plan's estimate).

**Release:** [OE4](#oe4-a-stand-in-geocoder-for-the-local-platform) and [OE5](#oe5-contact-verification-extracted-as-a-trait), as the alpha after the first.

### OE6: the visitor door on AWS, when the example is to sign visitors up there

Owned by [DW5](self-registration-is-a-chapter-not-a-trait.md#dw5-a-narrow-door-for-visitors-on-aws)
to [DW8](self-registration-is-a-chapter-not-a-trait.md#dw8-the-admission-check-and-the-shells-configuration-on-aws).
Not needed for running the example locally; listed so the order is in one place.

### OE7: the example's README says it

The README's *Run it locally* names the places file; *Packages* says `Customer` grafts the
contact-verification trait once [OE5](#oe5-contact-verification-extracted-as-a-trait) lands. Size S.

## 4. Order

[OE1](#oe1-a-category-brought-back-takes-products-again),
[OE2](#oe2-who-may-change-a-customer) and
[OE3](#oe3-a-plugin-with-no-slices-yet-builds) need nothing and go first, in one release.
[OE4](#oe4-a-stand-in-geocoder-for-the-local-platform) and
[OE5](#oe5-contact-verification-extracted-as-a-trait) can run beside each other after it.
[OE6](#oe6-the-visitor-door-on-aws-when-the-example-is-to-sign-visitors-up-there) follows its own
plan's order. [OE7](#oe7-the-examples-readme-says-it) closes each release.

## 5. Open questions

**OEQ1. Should the stand-in answer an address it does not know?** It could return a fixed point,
or a point hashed from the text, so every address lands somewhere.
**Recommendation: no.** A made-up point is a wrong location presented as a right one; the map
would show customers in places they do not live, and the trait's *unresolvable* path would never
run locally. A listed address resolves, an unlisted one stays queued, and the log says which.
Revisit if a demo needs every invented address on the map: then it lists them.

**OEQ2. How does an aggregate say the caller is this customer?** A DCB command marks its owner
field with `@owner`; the `Customer` aggregate is keyed by its id, which is the shopper's account
id, but nothing tells the framework to compare the two.
**Recommendation: compare the aggregate's id with the caller when the aggregate declares
`@owner` on its `Id` module**, and refuse otherwise unless the caller holds an elevated role, as
`PlaceOrder` already behaves. If that is more than a small change, ship [OE2](#oe2-who-may-change-a-customer) with the
administrator rule only, and file the owner rule as its own plan.
**Answered 2026-10-30: built as recommended**, since it was small. The marker is a functor,
`Reventless.Id.Owned(CustomerId)`, not an attribute, so the PPX did not change. See
[OE2](#oe2-who-may-change-a-customer).

## 6. Acceptance

- The two gaps of [§1](#1-why) are closed, each with the scenario that failed before.
- A plugin with no slices builds.
- On the local platform, with the places file, the seed fills the customers map.
- The contact-verification trait is extracted and grafted back, its suite bound.
- Every test of the example passes, and the seed's three data sets run locally.
