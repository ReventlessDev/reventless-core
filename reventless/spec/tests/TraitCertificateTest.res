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

// The manifest's one piece of inference: which config fields a graft must be
// given. Read off the emitter's own schema rather than listed by hand, so a
// field added there appears without anyone remembering to say so.

@schema
type sampleConfig = {
  entity: string,
  noun: string,
  authorize?: string,
  refA?: string,
}

describe("TraitManifest.configFieldsOf", () => {
  let fields = TraitManifest.configFieldsOf(sampleConfigSchema->S.castToUnknown)

  testSync("every declared field is listed, sorted by name", () =>
    expect(fields->Array.map(f => f.name))->toEqual(["authorize", "entity", "noun", "refA"])
  )

  // The half worth asserting: sury models `?` as a union with undefined, and
  // reading that wrong would publish an optional field as mandatory — a listing
  // telling a consumer to supply something the emitter defaults.
  testSync("an optional field is not required", () =>
    expect(fields->Array.filter(f => !f.required)->Array.map(f => f.name))->toEqual([
      "authorize",
      "refA",
    ])
  )

  testSync("a schema that is not an object yields nothing rather than throwing", () =>
    expect(TraitManifest.configFieldsOf(S.string->S.castToUnknown))->toEqual([])
  )
})
