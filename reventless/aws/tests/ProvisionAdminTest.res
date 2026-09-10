open JestGlobals

// The bootstrap script's two decidable parts: which pool and which person the run
// is about, and the credential it mints. Reachable at all only because the module
// defines `main` without calling it — `run-provision-admin.mjs` does that — which
// is the same reason its sibling is testable.
//
// The AWS calls themselves are not covered here. What is covered is everything
// that can be wrong *before* one is made, plus the password, which is the one
// value this script invents rather than passes through.

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

// The pool policy every Reventless pool is created with — 12+ characters, with a
// lowercase, an uppercase and a digit. `AdminSetUserPassword` refuses anything
// short of it, and a bootstrap that mints a password Cognito rejects strands the
// operator exactly where this script exists to rescue them.
//
// Sampled rather than asserted once. The construction is meant to satisfy the
// policy *always* rather than usually, so a single passing draw would prove
// nothing — the failure this guards against is precisely the rare one.
describe("ProvisionAdmin.generatePassword", () => {
  let samples = Array.fromInitializer(~length=200, _ => Provision.generatePassword())

  let holdsOneOf = (candidate, alphabet) =>
    candidate->String.split("")->Array.some(ch => alphabet->String.includes(ch))

  testSync("is as long as it says it is", () =>
    expect(samples->Array.every(p => p->String.length == Provision.passwordLength))->toBe(true)
  )

  testSync("always carries a lowercase, an uppercase and a digit", () =>
    expect(
      samples->Array.every(
        p =>
          p->holdsOneOf(Provision.lower) &&
          p->holdsOneOf(Provision.upper) &&
          p->holdsOneOf(Provision.digits),
      ),
    )->toBe(true)
  )

  // A character outside the alphabet would mean an index escaped its modulo, and
  // the symptom would be a password Cognito refuses for a reason the operator
  // cannot see.
  testSync("draws only from its own alphabet", () =>
    expect(
      samples->Array.every(
        p => p->String.split("")->Array.every(ch => Provision.alphabet->String.includes(ch)),
      ),
    )->toBe(true)
  )

  // Not a randomness test — it is the one that fails loudly if the generator is
  // ever replaced by something constant, which is the way this kind of helper
  // actually breaks.
  testSync("does not mint the same password twice", () =>
    expect(
      samples->Array.map(p => (p, true))->Dict.fromArray->Dict.keysToArray->Array.length,
    )->toBe(samples->Array.length)
  )

  // The glyphs a person confuses when retyping a printed credential. This
  // password is read off a terminal once, so a misread character sends the
  // operator back to the console the script exists to avoid.
  testSync("omits the characters that are misread when retyped", () =>
    expect(
      ["l", "I", "1", "O", "0"]->Array.some(ch => Provision.alphabet->String.includes(ch)),
    )->toBe(false)
  )
})
