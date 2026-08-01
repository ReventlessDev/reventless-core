// Empties a deployed AWS stack's durable stores so it can be re-seeded.
//
//   pnpm run seed:reset      # pick a scope, see the dry run, type the stack name to confirm
//
// This is the inverse of `pnpm run seed`: seeding refuses a non-empty store, and
// this makes a non-empty store empty again. The hybrid deploys as three Pulumi
// projects sharing a stack name — the platform plus the catalog and ordering
// plugins — so the reset offers a scope menu (domain = catalog + ordering, a
// single plugin, platform, or everything); `domain` is the default. Wiping domain
// alone leaves the platform's plugin registry intact, so a re-seed just works.
//
// It is fail-closed: each chosen project's stack must be on the name-allowlist
// (alpha, dev, pr-*) AND declare `reventless:wipeable: true` in its own
// Pulumi.<stack>.yaml, or the run refuses. Targets are discovered only through
// the `reventless:platform` + `reventless:environment` tags. Dry-run is the
// default; re-typing the stack name confirms a real wipe (or, in CI with no TTY,
// REVENTLESS_WIPE_CONFIRM=<stack>). AWS auth is the ambient credential chain
// (env / profile / SSO), not the Cognito login the seed uses — so no password.
//
// The project dirs are relative to this platform-aws dir (the seed cwd); the
// backend pin matches the seed script beside it. AWS credentials come from the
// ambient chain (env / profile / SSO).

// `plugin` is the name the project's plugin registers, which the platform's
// `objectStores` keys are qualified by — it is how an uploaded object is
// attributed to the plugin that declared its store. It differs from `label`
// only in case here, but stating it is what keeps the reset from guessing.
let targets: array<ReventlessSeedAws_Reset.target> = [
  {projectDir: "../catalog-aws", label: "catalog", group: Domain, plugin: "Catalog"},
  {projectDir: "../ordering-aws", label: "ordering", group: Domain, plugin: "Ordering"},
  {projectDir: ".", label: "platform", group: Platform},
]

ReventlessSeedAws_Reset.run(~backend="https://api.pulumi.com", ~targets, ())
