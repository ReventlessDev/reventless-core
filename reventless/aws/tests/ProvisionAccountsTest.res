open JestGlobals

// What can be decided before an AWS call is made: which pool and which manifest
// the run is about, and which usernames a pool could never authenticate.
//
// The applying itself is not covered here — it is four SDK calls in a loop. What
// is covered is the preflight, because its whole purpose is to fail *before*
// half a cast exists, and the argument parsing, because getting it wrong
// provisions the right accounts into the wrong deployment.
//
// The manifest's own rules — what a second run does to a password already in the
// file — live with the format, in `spec`'s `AccountsManifestTest`.

module Provision = ProvisionAccounts

describe("ProvisionAccounts.parseArgs", () => {
  testSync("no arguments leaves every choice unanswered", () =>
    expect(Provision.parseArgs([]))->toEqual(
      Ok({Provision.providerId: None, file: None, prepareOnly: false, help: false}),
    )
  )

  testSync("a pool and a manifest parse", () =>
    expect(
      Provision.parseArgs(["--provider-id", "eu-west-1_AbCdEfGhI", "--file", "cast.yaml"]),
    )->toEqual(
      Ok({
        Provision.providerId: Some("eu-west-1_AbCdEfGhI"),
        file: Some("cast.yaml"),
        prepareOnly: false,
        help: false,
      }),
    )
  )

  testSync("--prepare-only takes no value", () =>
    expect(Provision.parseArgs(["--prepare-only"]))->toEqual(
      Ok({Provision.providerId: None, file: None, prepareOnly: true, help: false}),
    )
  )

  // The reason unknown flags refuse rather than being skipped, and it lands
  // harder here than on the first administrator: a typo'd `--provider-id` falls
  // through to the environment and creates the whole cast in a different pool
  // than the operator named.
  testSync("an unknown flag refuses rather than being ignored", () =>
    expect(Provision.parseArgs(["--pool", "eu-west-1_AbCdEfGhI"]))->toEqual(
      Error(`unknown argument "--pool"`),
    )
  )

  testSync("a flag with no value refuses", () =>
    expect(Provision.parseArgs(["--provider-id"]))->toEqual(Error("--provider-id needs a value"))
  )

  testSync("-h asks for the usage", () =>
    expect(Provision.parseArgs(["-h"]))->toEqual(
      Ok({Provision.providerId: None, file: None, prepareOnly: false, help: true}),
    )
  )
})

// A manifest usually names plain usernames — `shopper`, `merch` — and a pool
// created with `UsernameAttributes: [email]` will not take them. The accounts it
// makes instead are correctly created and cannot authenticate, which is a symptom
// that arrives at a login screen far from the run that caused it.
describe("ProvisionAccounts.looksLikeEmail", () => {
  testSync("an address is one", () =>
    expect(Provision.looksLikeEmail("me@example.com"))->toBe(true)
  )

  testSync("a demo username is not", () => expect(Provision.looksLikeEmail("shopper"))->toBe(false))

  // Not a validator — Cognito owns that. It answers one question: would this pool
  // accept this string as a sign-in name. A local part with no domain would not.
  testSync("an @ with no domain dot is not", () =>
    expect(Provision.looksLikeEmail("admin@localhost"))->toBe(false)
  )
})
