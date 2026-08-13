// The storefront's surface: what a customer of this shop can see and do.
//
// Platform-independent on purpose. This answers "what does the storefront
// offer?", which is a fact about the app and is the same whether the shop runs
// on the in-memory platform or on AWS. Where and whether to HOST a shell is the
// platform-specific half, so each platform root passes this record in its own
// `hostUiBundle` rather than restating its contents.
//
// Curation, not authorization. Leaving a component out of this list keeps it out
// of the shell's surface; it does not make it any less callable. The server
// decides what a caller may do, per query and per mutation, and it decides the
// same thing whether or not a component is named here.
//
// Catalog management, the demand view and the customer list are operator
// surfaces and simply do not appear below, so a shell reading this cannot render
// them. `AvailableProducts` is likewise absent yet still reaches the shell:
// `PlaceOrder` @refs it, so it rides along as a reference target for the product
// picker while staying out of the menu.
let manifest: ReventlessInfra.Platform.bakedManifest = {
  components: [
    {plugin: "Catalog", views: ["Products", "Categories"], commands: []},
    {plugin: "Ordering", views: ["Orders"], commands: ["PlaceOrder", "CancelOrder"]},
  ],
  // One surface per role the shop has, beside the storefront every other caller
  // gets. Fulfilment is the reason this exists: it works a board of orders that
  // belong to customers, so it needs surfaces the storefront does not offer —
  // and it needs them from a file of its own, because a role elevated by
  // anything other than `Admin` has no admin API it may open.
  journeys: [
    {
      group: "Merchandiser",
      components: [
        {
          plugin: "Catalog",
          views: ["Products", "Categories", "ProductDemand"],
          commands: [
            "AddProduct",
            "ChangeProductPrice",
            "AddCategory",
            "RenameCategory",
          ],
        },
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

/**
How the storefront reads: nav labels and grouping, and the action that turns a
product card into a started order.

Beside the manifest for the reason the manifest is here — the shop's own
surface, stated once for every root that serves it. Presentation rather than
curation this time, and neither is a boundary: what a caller may see and do is
the server's answer, given per query and per mutation.

A path rather than a record because `uiHintsFile` takes one on both platforms —
the AWS deploy uploads the file's bytes and the local platform writes them into
the served bundle, so a deployment's hints reach the shell as the file it
fetches either way. Resolved from this module rather than from each root's
working directory, which differs per platform and would make the same
declaration two different files.
*/
let uiHintsFile = NodePath.resolve([NodeImportMeta.dirname, "../ui-hints.json"])

/**
Groups whose members read across every customer.

Here for the same reason the manifest is: it is a fact about this shop, not about
the platform hosting it, and every root that serves the shop has to agree on it.
An operator who is elevated on one deployment and scoped on another is a bug
nobody can reproduce.

Unlike the manifest above, this one is **not** curation — it decides what the
server does. A group named here reads every customer's orders. Leaving it empty
would scope administrators too, which is the safe direction and also means the
back-office order board shows an operator nothing.

`Merchandiser` is deliberately absent and always will be: maintaining the catalog
means editing products, which record no owner and so cannot be scoped away from
anybody. Elevating a role that does not need it buys nothing and widens what a
stolen session reaches.

`Fulfilment` is absent for a different reason, and a temporary one. Shipping an
order means working a board of orders that belong to customers, so the role does
need the exemption — but naming it here today breaks that account's shell.
The host UI sends any *elevated* caller to the admin API, and the admin API is
gated on the group `Admin` specifically, so a caller elevated by some other group
is routed to a door it cannot open. Until a role can be exempt from owner scoping
and still discover its surfaces from a manifest, `Fulfilment` reads its own rows
like anybody else — incomplete, and visibly so, rather than broken.
*/
let elevatedGroups = ["Admin"]
