open JestGlobals

// The bootstrap script's decidable part: which pool and which person the run is
// about. Reachable at all only because the module defines `main` without calling
// it — `run-provision-admin.mjs` does that — which is the same reason its sibling
// is testable.
//
// The AWS calls themselves are not covered here; what is covered is everything
// that can be wrong *before* one is made. The credential this script hands out is
// no longer its own — the generator moved to `spec` so the manifest's
// platform-neutral half could reach it, and `Util_PasswordTest` holds the policy
// it has to satisfy.

module Provision = ProvisionAdmin

describe("ProvisionAdmin.parseArgs", () => {
  testSync("both arguments parse", () =>
    expect(
      Provision.parseArgs(["--provider-id", "eu-west-1_AbCdEfGhI", "--email", "me@example.com"]),
    )->toEqual(
      Ok({
        Provision.providerId: Some("eu-west-1_AbCdEfGhI"),
        email: Some("me@example.com"),
        help: false,
      }),
    )
  )

  testSync("no arguments leaves both unanswered", () =>
    expect(Provision.parseArgs([]))->toEqual(
      Ok({Provision.providerId: None, email: None, help: false}),
    )
  )

  // The reason unknown flags refuse rather than being skipped: a typo'd
  // `--provider-id` would fall through to the environment and make the
  // administrator in a different pool than the operator named — a successful run
  // against the wrong deployment, which is worse than a failed one.
  testSync("an unknown flag refuses rather than being ignored", () =>
    expect(Provision.parseArgs(["--provider", "eu-west-1_AbCdEfGhI"]))->toEqual(
      Error(`unknown argument "--provider"`),
    )
  )

  testSync("a flag with no value refuses", () =>
    expect(Provision.parseArgs(["--email"]))->toEqual(Error("--email needs a value"))
  )

  testSync("-h asks for the usage", () =>
    expect(Provision.parseArgs(["-h"]))->toEqual(
      Ok({Provision.providerId: None, email: None, help: true}),
    )
  )
})
