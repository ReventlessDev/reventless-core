// Reports, per declared object store, what the event log actually references.
//
//   pnpm run seed:reconcile
//
// Read-only: it lists the store, scans every event log, and prints the four
// populations — referenced-and-still-tagged (must be zero), unreferenced-and-
// tagged (what an expiry rule would delete), unreferenced-and-untagged (minted
// before the claim component existed, and outside any rule), and refs pointing
// at objects that are gone.
//
// Run it before turning on a store's `pendingUploadExpiryDays`, and after the
// claim component has been live long enough to have caught up. A non-zero exit
// means at least one referenced object is still tagged pending — enabling expiry
// then would delete a live image.
//
// Same targets as the reset beside it: the platform project holds the store list
// (its `objectStores` stack output) and each plugin project holds the event logs
// whose events may reference them. AWS credentials come from the ambient chain
// (env / profile / SSO); set AWS_REGION.

let targets: array<ReventlessSeedAws_Reset.target> = [
  {projectDir: "../catalog-aws", label: "catalog", group: Domain, plugin: "Catalog"},
  {projectDir: "../ordering-aws", label: "ordering", group: Domain, plugin: "Ordering"},
  {projectDir: ".", label: "platform", group: Platform},
]

ReventlessSeedAws_Reconcile.run(~backend="https://api.pulumi.com", ~targets, ())
