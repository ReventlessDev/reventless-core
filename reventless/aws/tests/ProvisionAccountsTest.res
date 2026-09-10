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
      Ok({Provision.providerId: None, stack: None, file: None, help: false}),
    )
  )

  testSync("a pool and a manifest parse", () =>
    expect(
      Provision.parseArgs(["--provider-id", "eu-west-1_AbCdEfGhI", "--file", "cast.yaml"]),
    )->toEqual(
      Ok({
        Provision.providerId: Some("eu-west-1_AbCdEfGhI"),
        stack: None,
        file: Some("cast.yaml"),
        help: false,
      }),
    )
  )

  testSync("--stack picks the deployment to read the pool id from", () =>
    expect(Provision.parseArgs(["--stack", "beta"]))->toEqual(
      Ok({Provision.providerId: None, stack: Some("beta"), file: None, help: false}),
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
      Ok({Provision.providerId: None, stack: None, file: None, help: true}),
    )
  )
})

// Which pool a run writes to, which is the one decision that is expensive to get
// wrong: provisioning a cast into the wrong deployment succeeds, and leaves
// working accounts somewhere nobody is looking.
//
// The stack fallback is not exercised here — it shells out to `pulumi`, and a
// test that did would depend on a logged-in CLI and a deployed stack. What is
// covered is the precedence above it, and that every answer says where it came
// from, which is what makes a wrong-pool run visible rather than silent.
describe("ProvisionProvider.resolve", () => {
  let withoutEnv = fn => {
    let saved = NodeProcess.env->Dict.get(ProvisionProvider.envKey)
    NodeProcess.env->Dict.delete(ProvisionProvider.envKey)
    let outcome = fn()
    switch saved {
    | Some(value) => NodeProcess.env->Dict.set(ProvisionProvider.envKey, value)
    | None => ()
    }
    outcome
  }

  testSync("an explicit id wins, and says so", () =>
    expect(
      withoutEnv(
        () => ProvisionProvider.resolve(~given=Some("eu-west-1_Explicit"), ~stack=Some("alpha")),
      ),
    )->toEqual(Ok(("eu-west-1_Explicit", ProvisionProvider.Flag)))
  )

  // The flag beats the variable rather than the other way round: a CI shell that
  // exports one for every stack must still be overridable for a single run.
  testSync("an explicit id beats the environment", () => {
    NodeProcess.env->Dict.set(ProvisionProvider.envKey, "eu-west-1_FromEnv")
    let resolved = ProvisionProvider.resolve(~given=Some("eu-west-1_Explicit"), ~stack=None)
    NodeProcess.env->Dict.delete(ProvisionProvider.envKey)
    expect(resolved)->toEqual(Ok(("eu-west-1_Explicit", ProvisionProvider.Flag)))
  })

  testSync("the environment answers when no flag does", () => {
    NodeProcess.env->Dict.set(ProvisionProvider.envKey, "eu-west-1_FromEnv")
    let resolved = ProvisionProvider.resolve(~given=None, ~stack=None)
    NodeProcess.env->Dict.delete(ProvisionProvider.envKey)
    expect(resolved)->toEqual(Ok(("eu-west-1_FromEnv", ProvisionProvider.Environment)))
  })

  // An empty variable is not an answer. Exporting it unset is the ordinary shape
  // of a CI script whose earlier step did not run, and reading "" as the pool id
  // would fail much later with a message about Cognito rather than about setup.
  testSync("an empty environment variable is not an answer", () =>
    expect({
      NodeProcess.env->Dict.set(ProvisionProvider.envKey, "   ")
      let resolved = ProvisionProvider.resolve(~given=None, ~stack=Some("no-such-stack-here"))
      NodeProcess.env->Dict.delete(ProvisionProvider.envKey)
      resolved->Result.isError
    })->toBe(true)
  )

  testSync("each source describes itself", () => {
    expect(ProvisionProvider.describe(Flag))->toBe("--provider-id")
    expect(ProvisionProvider.describe(Environment))->toBe("REVENTLESS_IDENTITY_PROVIDER_ID")
    expect(ProvisionProvider.describe(Stack("beta")))->toBe("stack beta")
  })
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
