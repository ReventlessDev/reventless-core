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
}
