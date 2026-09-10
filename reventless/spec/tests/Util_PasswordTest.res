open JestGlobals

// The pool policy every Reventless pool is created with — 12+ characters, with a
// lowercase, an uppercase and a digit. `AdminSetUserPassword` refuses anything
// short of it, and a bootstrap that mints a password Cognito rejects strands the
// operator exactly where the provisioning scripts exist to rescue them.
//
// Sampled rather than asserted once. The construction is meant to satisfy the
// policy *always* rather than usually, so a single passing draw would prove
// nothing — the failure this guards against is precisely the rare one.

describe("Util_Password.generate", () => {
  let samples = Array.fromInitializer(~length=200, _ => Util_Password.generate())

  let holdsOneOf = (candidate, alphabet) =>
    candidate->String.split("")->Array.some(ch => alphabet->String.includes(ch))

  testSync("is as long as it says it is", () =>
    expect(samples->Array.every(p => p->String.length == Util_Password.length))->toBe(true)
  )

  testSync("always carries a lowercase, an uppercase and a digit", () =>
    expect(
      samples->Array.every(
        p =>
          p->holdsOneOf(Util_Password.lower) &&
          p->holdsOneOf(Util_Password.upper) &&
          p->holdsOneOf(Util_Password.digits),
      ),
    )->toBe(true)
  )

  // A character outside the alphabet would mean an index escaped its modulo, and
  // the symptom would be a password Cognito refuses for a reason the operator
  // cannot see.
  testSync("draws only from its own alphabet", () =>
    expect(
      samples->Array.every(
        p => p->String.split("")->Array.every(ch => Util_Password.alphabet->String.includes(ch)),
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

  // The glyphs a person confuses when retyping a printed credential. These
  // passwords are read off a terminal or out of a file once, so a misread
  // character sends the operator back to the console the scripts exist to avoid.
  testSync("omits the characters that are misread when retyped", () =>
    expect(
      ["l", "I", "1", "O", "0"]->Array.some(ch => Util_Password.alphabet->String.includes(ch)),
    )->toBe(false)
  )
})
