// ImportProduct InboundTranslationSlice.
// Receives external supplier JSON, validates and translates to an AddProduct command.
// The supplier posts to a signed webhook; the mutation stays as an operator's
// replay door, which is why the command needs Admin rather than any signed-in user.

@@reventless.spec
@@reventless.authorize(AllowRoles([Admin]))

@schema
type externalInput = {
  sku: string,
  title: string,
  desc: string,
  unitPrice: int,
  currency: string,
}

@schema
type command =
  AddProduct({productId: CatalogSpec.ProductId.t, name: string, description: string, price: float})

let targetName = "AddProduct"
// Foreign system this anti-corruption slice receives product data from — drawn as an
// external box outside the Catalog plugin in the Event Graph.
let externalSystem = Some("SupplierFeed")

// A feed is only mapped, so nothing is provisioned on its behalf.
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []

// The supplier signs each post with the secret `supplierFeed`
// (`pulumi config set --secret webhook:supplierFeed …` on AWS,
// `REVENTLESS_WEBHOOK_SECRET_SUPPLIERFEED` locally); a signed post acts as Admin.
let endpoint = Some({
  Reventless.InboundTranslationSlice.path: "supplier-feed",
  auth: SignedBody({
    header: "X-Signature-256",
    prefix: "sha256=",
    timestampHeader: "X-Signature-Timestamp",
    secret: "supplierFeed",
  }),
  role: Roles.Admin,
})
