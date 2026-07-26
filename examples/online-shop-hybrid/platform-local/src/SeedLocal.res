// Seeds the local dev platform with the shared hybrid demo data set(s).
//
//   pnpm run serve:reset   # in one shell
//   pnpm run seed          # in another — pick a set, then log in (admin/admin)
//
// The provider is not a choice here: this script targets local by construction.
// The data set(s) come from the shareable `online-shop-hybrid-seed` package; the
// localhost endpoints and the `/__inmemory/login` round-trip come from
// `Seed.Connect.local`. If more than one set exists, the runner prompts which to
// seed (or `SEED_SET` selects one non-interactively).

open ReventlessSeed
open OnlineShopHybridSeed

Seed.Runner.seed(~sets=HybridSeedData.dataSets, ~connect=Seed.Connect.local())
