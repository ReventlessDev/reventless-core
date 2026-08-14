// Seeds the local dev platform with the shared hybrid demo data set(s).
//
//   pnpm run serve:reset   # in one shell
//   pnpm run seed          # in another — pick a set, then log in (admin/admin)
//
// The provider is not a choice here: this script targets local by construction.
// The data set(s) come from the shareable `online-shop-hybrid-seed` package. If
// more than one set exists, the runner prompts which to seed (`SEED_SET` selects
// one non-interactively).
//
// WHICH platform is a second question, and `LocalSeedTarget.connect` answers it
// the same way: from the platforms actually running here, prompting only when
// there are several (`SEED_PLATFORM`), and printing the endpoint and store it
// picked. `Seed.Connect.local`'s localhost defaults are the fallback, not the
// assumption — with two platforms up they sent this script and `seed:reset` to
// different stores.

open ReventlessSeed
open OnlineShopHybridSeed

Seed.Runner.seed(
  ~sets=HybridSeedData.dataSets,
  ~connect=ReventlessLocal.LocalSeedTarget.connect(),
)
