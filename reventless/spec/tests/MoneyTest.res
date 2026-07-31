open JestGlobals

// `Money` is the first semantic type whose correctness is arithmetic rather
// than grammatical. A branded scalar is right when it rejects the values it
// should; this one is right when it *places the decimal point*, and it can only
// do that because the currency travels with the number.
//
// So the load-bearing cases below are the two currencies that are not like EUR:
// JPY has no minor unit at all and TND has three. A suite that only exercises a
// 2-decimal currency proves nothing that a hardcoded `/100` would not also pass.
describe("Money:", () => {
  let m = (amount, currency): Money.t => {amount, currency}

  describe("the currency table is generated from the standard:", () => {
    testSync("every currency has an exponent — the whole point of closing the type", () =>
      expect(Currency.all->Array.every(c => Currency.exponent(c) >= 0))->toBe(true)
    )

    testSync("the codes ISO defines are there", () =>
      expect(
        ["EUR", "USD", "GBP", "JPY", "TND", "CHF"]->Array.every(code =>
          Currency.fromString(code)->Result.isOk
        ),
      )->toBe(true)
    )

    // A curated subset would have made this a compile error in a consumer's
    // domain, fixable only by a framework release. Two currencies nobody would
    // have thought to list.
    testSync("and so are the ones a curated list would have missed", () =>
      expect(
        ["MGA", "STN", "ZWG", "VUV"]->Array.every(code => Currency.fromString(code)->Result.isOk),
      )->toBe(true)
    )

    // The entries ISO carries with no minor unit. Admitting them would make
    // `exponent` partial, which is the one property this type exists to have.
    testSync("the metals and the sentinels are not currencies", () =>
      expect(
        ["XAU", "XAG", "XDR", "XXX", "XTS"]->Array.some(code =>
          Currency.fromString(code)->Result.isOk
        ),
      )->toBe(false)
    )

    testSync("the exponents match ISO 4217", () =>
      expect(
        ["EUR", "JPY", "TND", "CLF"]->Array.map(code =>
          switch Currency.fromString(code) {
          | Ok(c) => Currency.exponent(c)
          | Error(_) => -1
          }
        ),
      )->toEqual([2, 0, 3, 4])
    )

    // The failure this type exists to prevent, and the one that already cost
    // this program a day: two spellings of one currency that simply never match.
    testSync("a lower-case code is rejected, not repaired", () =>
      expect(Currency.fromString("eur")->Result.isOk)->toBe(false)
    )

    testSync("the rejection says what it wanted and shows the value", () =>
      expect(
        switch Currency.fromString("eur") {
        | Error(why) => why->String.includes("ISO 4217") && why->String.includes("eur")
        | Ok(_) => false
        },
      )->toBe(true)
    )

    // `fromString` is derived from `all`, so this cannot drift — which is the
    // reason it is derived rather than a third generated switch.
    testSync("every listed currency round-trips through its code", () =>
      expect(
        Currency.all->Array.every(c =>
          switch Currency.fromString(Currency.toString(c)) {
          | Ok(back) => back == c
          | Error(_) => false
          }
        ),
      )->toBe(true)
    )
  })

  describe("format places the decimal point from the currency:", () => {
    let format = (amount, currency) => Money.format(m(amount, currency))

    testSync("two decimals for EUR", () => expect(format(1000.0, EUR))->toBe("10.00 EUR"))

    // The two cases that decide whether the exponent is real or decorative.
    testSync("none for JPY", () => expect(format(1000.0, JPY))->toBe("1,000 JPY"))
    testSync("three for TND", () => expect(format(1000.0, TND))->toBe("1.000 TND"))
    testSync("four for CLF", () => expect(format(1000.0, CLF))->toBe("0.1000 CLF"))

    testSync("an amount under one unit keeps its leading zero", () =>
      expect(format(5.0, EUR))->toBe("0.05 EUR")
    )
    testSync("zero", () => expect(format(0.0, EUR))->toBe("0.00 EUR"))
    testSync("thousands are grouped", () =>
      expect(format(123456789.0, USD))->toBe("1,234,567.89 USD")
    )
    testSync("a refund is money", () => expect(format(-2550.0, EUR))->toBe("-25.50 EUR"))
  })

  describe("ofMajor converts a decimal at the boundary:", () => {
    testSync("EUR scales by 100", () =>
      expect(Money.ofMajor(~amount=10.5, ~currency=EUR))->toEqual(m(1050.0, EUR))
    )

    // The reason this lives on the type rather than at each call site: written
    // by hand it is `*. 100.0`, which is wrong for both of these.
    testSync("JPY scales by 1", () =>
      expect(Money.ofMajor(~amount=1000.0, ~currency=JPY))->toEqual(m(1000.0, JPY))
    )
    testSync("TND scales by 1000", () =>
      expect(Money.ofMajor(~amount=1.5, ~currency=TND))->toEqual(m(1500.0, TND))
    )

    testSync("it rounds to a whole minor unit", () =>
      expect(Money.ofMajor(~amount=10.004, ~currency=EUR).amount)->toBe(1000.0)
    )

    testSync("what it produces is always valid money", () =>
      expect(Money.validateAmount(Money.ofMajor(~amount=0.1 +. 0.2, ~currency=EUR).amount))
      ->toEqual(Ok(30.0))
    )

    testSync("toMajor is its inverse for a whole major amount", () =>
      expect(Money.toMajor(Money.ofMajor(~amount=1234.56, ~currency=EUR)))->toBe(1234.56)
    )
  })

  describe("add checks the currency rather than assuming it:", () => {
    testSync("same currency adds", () =>
      expect(Money.add(m(100.0, EUR), m(50.0, EUR)))->toEqual(
        Ok(m(150.0, EUR)),
      )
    )

    // §15.1's second rider. The branded-scalar shape would have made this
    // unrepresentable by deleting the currency; keeping it means the mix is
    // caught instead of silently summed into a meaningless number.
    testSync("different currencies do not", () =>
      expect(
        Money.add(m(100.0, EUR), m(50.0, USD))->Result.isOk,
      )->toBe(false)
    )

    testSync("and the refusal names both amounts", () =>
      expect(
        switch Money.add(m(100.0, EUR), m(50.0, USD)) {
        | Error(why) => why->String.includes("1.00 EUR") && why->String.includes("0.50 USD")
        | Ok(_) => false
        },
      )->toBe(true)
    )

    testSync("exactness is why the amount is in minor units", () =>
      // The float equivalent — 0.1 +. 0.2 — is not 0.3.
      expect(Money.add(m(10.0, EUR), m(20.0, EUR)))->toEqual(
        Ok(m(30.0, EUR)),
      )
    )

    testSync("sum refuses at the first currency that does not match", () =>
      expect(
        Money.sum([
          m(100.0, EUR),
          m(50.0, EUR),
          m(1.0, GBP),
        ])->Option.map(Result.isOk),
      )->toEqual(Some(false))
    )

    testSync("the sum of no amounts has no currency to be in", () =>
      expect(Money.sum([])->Option.isNone)->toBe(true)
    )
  })

  describe("the schema:", () => {
    let parses = (raw: JSON.t) =>
      switch raw->S.parseOrThrow(Money.schema) {
      | _ => true
      | exception _ => false
      }

    let money = (amount, currency) =>
      JSON.Encode.object(
        Dict.fromArray([
          ("amount", JSON.Encode.float(amount)),
          ("currency", JSON.Encode.string(currency)),
        ]),
      )

    testSync("carries the money id", () =>
      expect(Money.schema->S.castToUnknown->Semantic.has(~id="money"))->toBe(true)
    )

    // The vocabulary id is a string contract with a consumer in another repo
    // that nothing type-checks across the boundary. Compared to a literal on
    // purpose, exactly as the branded scalars are.
    testSync("and the id is the wire string", () => expect(Semantic.Id.money)->toBe("money"))

    testSync("accepts an amount in minor units", () => expect(parses(money(1000.0, "EUR")))->toBe(true))
    testSync("accepts a negative amount", () => expect(parses(money(-1000.0, "EUR")))->toBe(true))

    // The check the type would have got for free from `int`, if `int` could
    // hold a real amount. Half a cent is not a value the log may contain.
    testSync("rejects a fraction of a minor unit", () =>
      expect(parses(money(10.5, "EUR")))->toBe(false)
    )
    testSync("rejects a non-finite amount", () =>
      expect(
        switch S.parseOrThrow(money(0.0, "EUR"), Money.schema) {
        | _ => Money.validateAmount(Float.Constants.nan)->Result.isOk
        | exception _ => true
        },
      )->toBe(false)
    )

    // Why `float` and not `int`: ReScript's `int` is int32, so an `int` amount
    // stops at €21,474,836.47. A framework money type that cannot express a
    // €22M total is not one — the same correction `Bytes` already made.
    testSync("accepts an amount an int32 could not hold", () =>
      expect(parses(money(9_000_000_000.0, "EUR")))->toBe(true)
    )

    testSync("rejects an unknown currency code", () =>
      expect(parses(money(1000.0, "QQQ")))->toBe(false)
    )
    testSync("rejects a lower-case currency code", () =>
      expect(parses(money(1000.0, "eur")))->toBe(false)
    )

    // The wire form is the ISO code, not the variant's ReScript spelling —
    // standard at the boundary, checked type in the domain.
    testSync("serializes the currency as its three-letter code", () =>
      expect(m(1000.0, EUR)->S.reverseConvertToJsonOrThrow(Money.schema))
      ->toEqual(money(1000.0, "EUR"))
    )
  })
})
