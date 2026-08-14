open JestGlobals

// The contract in Auth_RefusalVocabulary is a mapping between two adapters that
// cannot answer alike. The AWS rows cannot be asserted from a checkout — they
// need a deployed API — so what is asserted here is the *table*: that it names
// both adapters, that entitlement stays distinguishable from identity in each,
// and that `classify` resolves the collision the two AppSync values create.
//
// Observed bodies behind these rows: docs/plans/appsync-group-authorization-unenforced.md §8.

open ReventlessCore.Auth_RefusalVocabulary

describe("Auth_RefusalVocabulary — the table", () => {
  testSync("names both adapters", () => {
    expect(signalsFor(Local)->Array.length)->toBeGreaterThan(0)
    expect(signalsFor(AppSync)->Array.length)->toBeGreaterThan(0)
  })

  testSync("each adapter can express both refusals", () => {
    [Local, AppSync]->Array.forEach(adapter => {
      let kinds = signalsFor(adapter)->Array.map(s => s.kind)
      expect(kinds->Array.includes(Entitlement))->toBe(true)
      expect(kinds->Array.includes(Identity))->toBe(true)
    })
  })

  testSync("within an adapter the two refusals are actually distinguishable", () => {
    // A mapping whose two rows look identical to a client would be worthless —
    // it has to differ in the status, the place to look, or the value found.
    [Local, AppSync]->Array.forEach(adapter => {
      let signals = signalsFor(adapter)
      let entitlement = signals->Array.find(s => s.kind == Entitlement)
      let identity = signals->Array.find(s => s.kind == Identity)
      switch (entitlement, identity) {
      | (Some(e), Some(i)) =>
        let differs =
          e.httpStatus != i.httpStatus || e.discriminator != i.discriminator || e.value != i.value
        expect(differs)->toBe(true)
      | _ => JsError.throwWithMessage("adapter is missing one of the two refusals")
      }
    })
  })
})

describe("Auth_RefusalVocabulary.classify", () => {
  testSync("classifies every row of the table as that row's kind", () => {
    signals->Array.forEach(s => {
      let errorType = s.discriminator->String.includes("errorType") ? Some(s.value) : None
      let extensionsCode = s.discriminator == "extensions.code" ? Some(s.value) : None
      // The 401 row's discriminator is a response header; status alone carries it.
      expect(classify(~httpStatus=s.httpStatus, ~errorType?, ~extensionsCode?))->toEqual(Some(s.kind))
    })
  })

  // The trap the table exists to defuse: on AppSync the entitlement value is a
  // strict prefix of the identity one. A client matching by substring collapses
  // them, and collapses them the dangerous way — signing out a caller whose
  // session was fine.
  testSync("Unauthorized and UnauthorizedException are opposite answers", () => {
    expect(classify(~httpStatus=200, ~errorType="Unauthorized"))->toEqual(Some(Entitlement))
    expect(classify(~httpStatus=401, ~errorType="UnauthorizedException"))->toEqual(Some(Identity))
  })

  testSync("a 401 is identity even when a field error would say otherwise", () => {
    // Status is checked first precisely so this cannot go the other way.
    expect(classify(~httpStatus=401, ~errorType="Unauthorized"))->toEqual(Some(Identity))
  })

  testSync("the local codes map to the same two kinds as the AppSync shapes", () => {
    expect(classify(~httpStatus=200, ~extensionsCode="FORBIDDEN"))->toEqual(Some(Entitlement))
    expect(classify(~httpStatus=200, ~extensionsCode="UNAUTHORIZED"))->toEqual(Some(Identity))
  })

  testSync("an unrecognised response is None, which is not 'allowed'", () => {
    expect(classify(~httpStatus=200))->toEqual(None)
    expect(classify(~httpStatus=200, ~errorType="ValidationError"))->toEqual(None)
    expect(classify(~httpStatus=500))->toEqual(None)
  })
})

describe("Auth_RefusalVocabulary.warrantsReauthentication", () => {
  testSync("only an identity refusal asks the caller for new credentials", () => {
    expect(warrantsReauthentication(Identity))->toBe(true)
    expect(warrantsReauthentication(Entitlement))->toBe(false)
  })

  testSync("no adapter's entitlement refusal ends a session", () => {
    // The regression this whole contract exists to prevent, stated once.
    signals
    ->Array.filter(s => s.kind == Entitlement)
    ->Array.forEach(s => expect(warrantsReauthentication(s.kind))->toBe(false))
  })
})
