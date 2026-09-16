// Seeds a deployed AWS stack with the shared hybrid demo data set(s).
//
//   pnpm run seed          # pick a stack (or set SEED_STACK), then log in
//
// The provider is not a choice here: this script targets AWS by construction.
// Stack discovery, endpoint resolution (host-shell config.json or stack
// outputs), and Cognito login live in `reventless-seed-aws`; the data set(s)
// come from the shared `online-shop-hybrid-seed` package. The Pulumi stacks are
// this package's own `Pulumi.<stack>.yaml`, so the project dir is the default `.`.
//
// The stack is read from whatever backend the `pulumi` CLI is logged into;
// `SEED_PULUMI_BACKEND` names another one for a single run.

open ReventlessSeed
open OnlineShopHybridSeed

Seed.Runner.seed(~sets=HybridSeedData.dataSets, ~connect=ReventlessSeedAws.connect())
