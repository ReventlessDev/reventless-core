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
//
// `derived: []` answers the other half of the same question. A shell also builds
// pages ACROSS a plugin's views — a dashboard, a lifecycle diagram, a calendar —
// and those are operator surfaces too: a customer reading their own orders has
// no use for a state machine of every order status, and every one of them lands
// in a menu group named after the plugin, which is how a shop ends up offering
// "Ordering" beside "Shop". The storefront takes none of them; the roles that
// work those boards take the ones their job needs, below.
let manifest: ReventlessInfra.Platform.bakedManifest = {
  components: [
    {plugin: "Catalog", views: ["Products", "Categories"], commands: [], derived: []},
    {
      plugin: "Ordering",
      views: ["Orders"],
      commands: ["PlaceOrder", "CancelOrder"],
      derived: [],
    },
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
          // A catalog has no lifecycle and no dated view, so nothing here is
          // generated today. Said anyway, because the alternative is that the
          // first `@metric` a product gains hands this role a dashboard nobody
          // asked for — an include-list that only lists what already exists is
          // an include-list in name.
          derived: [],
        },
      ],
    },
    {
      group: "Fulfilment",
      components: [
        {
          plugin: "Ordering",
          views: ["Orders"],
          commands: ["ShipOrder", "CancelOrder"],
          // The board this role works: `Orders` carries a status and the
          // commands that move it, so the lifecycle diagram is a picture of the
          // job, and its delivery windows make a calendar of the same rows.
          // Both are what the storefront declines, which is the point of the
          // list being per-journey rather than per-deployment.
          derived: ["lifecycles", "canvas"],
        },
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

`Fulfilment` is here for the reason `Merchandiser` is not: shipping an order
means working a board of orders that belong to customers, so the role reads
across owners as its ordinary job rather than as an administrative exception.

It was held back for a while, and what held it back is worth keeping in view
because it was never about ownership. Being elevated used to decide *where the
shell looks for its surfaces* as well — any elevated caller was sent to the admin
API, which is gated on the group `Admin` specifically, so a role elevated by any
other name was routed to a door it could not open. The two questions now come
apart: the shell reads the admin gate from the group the server actually
enforces, and a role with a journey discovers from that journey's own file. So
naming a second group here answers only the question this list asks.
*/
let elevatedGroups = ["Admin", "Fulfilment"]
