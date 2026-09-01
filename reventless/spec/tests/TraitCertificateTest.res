// What a listing is allowed to claim, away from any runner.
//
// The badge rule is the whole point of this module existing rather than a shape
// each consumer assembles: a registry and a build gate must not be able to
// disagree about what "verified" means.

open JestGlobals

let cert = results =>
  TraitCertificate.fromReport(
    ~trait="@scope/trait-example",
    ~traitVersion="1.2.3",
    ~framework="3.0.0",
    ~host="Widgets",
    ~suite="Widgets conforms to the example trait",
    ~results,
  )

describe("TraitCertificate", () => {
  describe("fromReport", () => {
    testSync("counts are derived, not asserted by the caller", () => {
      let c = cert([("a", true), ("b", false), ("c", true)])
      expect((c.passed, c.failed))->toEqual((2, 1))
    })

    // Named, not numbered. A count that changed says nothing; an assertion that
    // disappeared says everything, and only the names carry that.
    testSync("every assertion is carried by name, in report order", () =>
      expect(cert([("b", true), ("a", false)]).assertions->Array.map(a => a.name))->toEqual([
        "b",
        "a",
      ])
    )
  })

  describe("verified", () => {
    testSync("all passing is verified", () =>
      expect(cert([("a", true), ("b", true)])->TraitCertificate.verified)->toBe(true)
    )

    testSync("one failure is not", () =>
      expect(cert([("a", true), ("b", false)])->TraitCertificate.verified)->toBe(false)
    )

    // The case worth having a rule for. A binding that registers nothing produces
    // an all-passing certificate with no assertions, which is exactly the shape a
    // broken graft takes — and certifying it would certify silence.
    testSync("an empty suite is not verified, however few failures it has", () =>
      expect(cert([])->TraitCertificate.verified)->toBe(false)
    )
  })

  describe("render", () => {
    testSync("is byte-stable and newline-terminated", () => {
      let c = cert([("a", true)])
      expect((
        c->TraitCertificate.render == c->TraitCertificate.render,
        c->TraitCertificate.render->String.endsWith("\n"),
      ))->toEqual((true, true))
    })

    testSync("round-trips through its own schema", () => {
      let c = cert([("a", true), ("b", false)])
      let decoded =
        c
        ->TraitCertificate.render
        ->JSON.parseOrThrow
        ->Util_Sury.fromJson(TraitCertificate.schema)
      expect(decoded)->toEqual(c)
    })
  })

  describe("summarize", () => {
    testSync("says the verdict, not only the numbers", () =>
      expect(cert([("a", false)])->TraitCertificate.summarize->String.includes("NOT verified"))
      ->toBe(true)
    )
  })
})
