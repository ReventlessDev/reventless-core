open JestGlobals

// Argument handling for the operator script. Testable at all only because the
// module no longer calls `main` at the top level — `run-provision-identity.mjs`
// does. While it ran itself on import, nothing in here could be reached, and
// that is how a guard that could never match shipped in the same file.
//
// What these cover is the one thing this script does that is hard to undo:
// deciding whether to *adopt* a user pool or *create* one.

module Provision = ProvisionIdentity

describe("ProvisionIdentity.parseArgs", () => {
  testSync("no arguments means adopt-or-create the default name", () =>
    expect(Provision.parseArgs([]))->toEqual(
      Ok({
        Provision.poolName: Provision.defaultPoolName,
        providerId: None,
        help: false,
      }),
    )
  )

  testSync("--provider-id names an existing pool", () =>
    expect(Provision.parseArgs(["--provider-id", "eu-west-1_AbCdEfGhI"]))->toEqual(
      Ok({
        Provision.poolName: Provision.defaultPoolName,
        providerId: Some("eu-west-1_AbCdEfGhI"),
        help: false,
      }),
    )
  )

  testSync("--name selects which pool to adopt by name", () =>
    expect(Provision.parseArgs(["--name", "examples-dev"]))->toEqual(
      Ok({Provision.poolName: "examples-dev", providerId: None, help: false}),
    )
  )

  testSync("both together are accepted, and the id wins at resolve time", () =>
    expect(Provision.parseArgs(["--name", "ignored", "--provider-id", "eu-west-1_x"]))->toEqual(
      Ok({Provision.poolName: "ignored", providerId: Some("eu-west-1_x"), help: false}),
    )
  )

  // 🚨 The reason unknown flags are refused rather than skipped. A misspelled
  // `--provider-id` that parsed as "absent" would silently take the *create* path
  // and stand up a second user pool beside the one the operator meant to extend.
  testSync("a misspelled flag is refused, not ignored", () =>
    expect(Provision.parseArgs(["--provider_id", "eu-west-1_x"]))->toEqual(
      Error(`unknown argument "--provider_id"`),
    )
  )

  // Same hazard from the other direction: a flag whose value was left off must
  // not read as "no id given".
  testSync("a flag with no value is refused", () =>
    expect(Provision.parseArgs(["--provider-id"]))->toEqual(
      Error("--provider-id needs a value"),
    )
  )

  testSync("--name with no value is refused too", () =>
    expect(Provision.parseArgs(["--name"]))->toEqual(Error("--name needs a value"))
  )

  testSync("--help and -h both ask for the usage text", () =>
    expect((
      Provision.parseArgs(["--help"])->Result.map(a => a.help),
      Provision.parseArgs(["-h"])->Result.map(a => a.help),
    ))->toEqual((Ok(true), Ok(true)))
  )

  // The first error stops the scan rather than the last one winning: an operator
  // fixing what they are told about should not then meet a second surprise.
  testSync("the first refusal is the one reported", () =>
    expect(Provision.parseArgs(["--nope", "--also-nope"]))->toEqual(
      Error(`unknown argument "--nope"`),
    )
  )
})

// The pool this script creates when it creates one. Asserted because a pool is
// the one thing here that outlives every stack — nothing in a `pulumi destroy`
// touches it — so its settings are not a detail an operator can revise cheaply
// once accounts exist in it.
describe("ProvisionIdentity.poolSettings", () => {
  let settings = Provision.poolSettings(~poolName="MyIdentity")

  testSync("carries the name it was asked for", () =>
    expect(settings.poolName)->toBe("MyIdentity")
  )

  testSync("matches what auto mode declares: email sign-in, no MFA, admin-only", () =>
    expect((
      settings.usernameAttributes,
      settings.mfaConfiguration,
      settings.adminCreateUserConfig->Option.flatMap(c => c.allowAdminCreateUserOnly),
    ))->toEqual((Some(["email"]), Some("OFF"), Some(true)))
  )

  testSync("keeps the 12-character password policy", () =>
    expect(
      settings.policies
      ->Option.flatMap(p => p.passwordPolicy)
      ->Option.flatMap(p => p.minimumLength),
    )->toEqual(Some(12))
  )
})
