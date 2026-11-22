// Backfills the dates a lifecycle trail derives on this deployment's view rows.
//
//   AWS_REGION=… SEED_STACK=alpha pnpm run views:rederive            # dry run
//   AWS_REGION=… SEED_STACK=alpha pnpm run views:rederive -- --apply # writes
//
// AWS credentials come from the ambient chain (env / profile / SSO).

let targets: array<ReventlessSeedAws_Reset.target> = [
  {projectDir: "../catalog-aws", label: "catalog", group: Domain, plugin: "Catalog"},
  {projectDir: "../ordering-aws", label: "ordering", group: Domain, plugin: "Ordering"},
  {projectDir: ".", label: "platform", group: Platform},
]

ReventlessSeedAws_Rederive.run(~targets, ())
