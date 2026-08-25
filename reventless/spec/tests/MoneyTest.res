open JestGlobals

// `Money` is the first semantic type whose correctness is arithmetic rather
// than grammatical. A branded scalar is right when it rejects the values it
// should; this one is right when it *knows how precise an amount may be*, and it
// can only do that because the currency travels with the number.
//
// So the load-bearing currency below is JPY: it has no decimal place at all,
// where every other admitted code has two. A suite that only exercises EUR
// proves nothing that a hardcoded two would not also pass.
describe("Money:", () => {
  let m = (amount, currency): Money.t => {amount, currency}

  describe("the currency table is generated from the standard:", () => {
    testSync("every currency has an exponent — the whole point of closing the type", () =>
      expect(Currency.all->Array.every(c => Currency.exponent(c) >= 0))->toBe(true)
    )

    testSync("the codes the framework admits are there", () =>
      expect(
        ["EUR", "USD", "GBP", "JPY", "CHF", "CNY"]->Array.every(code =>
          Currency.fromString(code)->Result.isOk
        ),
      )->toBe(true)
    )

    // The set is curated, so a code ISO defines is not necessarily a code this
    // type admits. Rejected the same way an invented one is — the caller's next
    // move is to admit it in the generator, not to correct the spelling.
    testSync("a dormant ISO code is not a currency here", () =>
      expect(
        ["AED", "TND", "SGD", "ZAR"]->Array.some(code => Currency.fromString(code)->Result.isOk),
      )->toBe(false)
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
        ["EUR", "JPY", "SEK"]->Array.map(code =>
          switch Currency.fromString(code) {
          | Ok(c) => Currency.exponent(c)
          | Error(_) => -1
          }
        ),
      )->toEqual([2, 0, 2])
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

  describe("format shows the decimals the currency has:", () => {
    let format = (amount, currency) => Money.format(m(amount, currency))

    testSync("two for EUR", () => expect(format(10.0, EUR))->toBe("10.00 EUR"))

    // The case that decides whether the exponent is real or decorative.
    testSync("none for JPY", () => expect(format(1000.0, JPY))->toBe("1,000 JPY"))

    testSync("an amount under one unit keeps its leading zero", () =>
      expect(format(0.05, EUR))->toBe("0.05 EUR")
    )
    testSync("zero", () => expect(format(0.0, EUR))->toBe("0.00 EUR"))
    testSync("thousands are grouped", () =>
      expect(format(1234567.89, USD))->toBe("1,234,567.89 USD")
    )
    testSync("a refund is money", () => expect(format(-25.5, EUR))->toBe("-25.50 EUR"))
  })

  describe("make rounds to what the currency holds:", () => {
    testSync("an amount the currency can hold is untouched", () =>
      expect(Money.make(~amount=10.5, ~currency=EUR))->toEqual(m(10.5, EUR))
    )

    testSync("a third decimal is rounded away for EUR", () =>
      expect((
        Money.make(~amount=10.004, ~currency=EUR).amount,
        Money.make(~amount=10.006, ~currency=EUR).amount,
      ))->toEqual((10.0, 10.01))
    )

    // The reason rounding lives on the type rather than at each call site:
    // written by hand it is a `toFixed(2)`, which is wrong for this.
    testSync("JPY has no decimals to round to", () =>
      expect(Money.make(~amount=1000.4, ~currency=JPY).amount)->toBe(1000.0)
    )

    // `Math.round` alone rounds half toward positive infinity, so a refund would
    // round the other way from the charge it reverses.
    testSync("a half rounds away from zero in both directions", () =>
      expect((
        Money.make(~amount=2.5, ~currency=JPY).amount,
        Money.make(~amount=-2.5, ~currency=JPY).amount,
      ))->toEqual((3.0, -3.0))
    )

    testSync("what it produces is always valid money", () =>
      expect(
        Money.validate(~amount=Money.make(~amount=0.1 +. 0.2, ~currency=EUR).amount, ~currency=EUR),
      )->toEqual(Ok(0.3))
    )
  })

  // The scale is not gone, it is contained: a payment gateway and a supplier
  // feed both count in minor units, and this is the one place that conversion is
  // written down.
  describe("ofMinor converts what an external system counts in:", () => {
    testSync("EUR divides by 100", () =>
      expect(Money.ofMinor(~units=1050.0, ~currency=EUR))->toEqual(m(10.5, EUR))
    )
    testSync("JPY divides by 1 — the case a hand-written /100 gets wrong", () =>
      expect(Money.ofMinor(~units=1000.0, ~currency=JPY))->toEqual(m(1000.0, JPY))
    )
    testSync("toMinor is its inverse", () =>
      expect(Money.toMinor(Money.ofMinor(~units=1234.0, ~currency=EUR)))->toBe(1234.0)
    )
  })

  describe("add checks the currency rather than assuming it:", () => {
    testSync("same currency adds", () =>
      expect(Money.add(m(1.0, EUR), m(0.5, EUR)))->toEqual(Ok(m(1.5, EUR)))
    )

    // §15.1's second rider. The branded-scalar shape would have made this
    // unrepresentable by deleting the currency; keeping it means the mix is
    // caught instead of silently summed into a meaningless number.
    testSync("different currencies do not", () =>
      expect(Money.add(m(1.0, EUR), m(0.5, USD))->Result.isOk)->toBe(false)
    )

    testSync("and the refusal names both amounts", () =>
      expect(
        switch Money.add(m(1.0, EUR), m(0.5, USD)) {
        | Error(why) => why->String.includes("1.00 EUR") && why->String.includes("0.50 USD")
        | Ok(_) => false
        },
      )->toBe(true)
    )

    // What the minor-unit representation used to buy, kept: the plain float
    // equivalent — 0.1 +. 0.2 — is not 0.3.
    testSync("addition is exact", () =>
      expect(Money.add(m(0.1, EUR), m(0.2, EUR)))->toEqual(Ok(m(0.3, EUR)))
    )

    testSync("and stays exact over a long run", () =>
      expect(Money.sum(Array.make(~length=10, m(0.1, EUR))))->toEqual(Some(Ok(m(1.0, EUR))))
    )

    testSync("sum refuses at the first currency that does not match", () =>
      expect(
        Money.sum([m(1.0, EUR), m(0.5, EUR), m(1.0, GBP)])->Option.map(Result.isOk),
      )->toEqual(Some(false))
    )

    testSync("the sum of no amounts has no currency to be in", () =>
      expect(Money.sum([])->Option.isNone)->toBe(true)
    )
  })

  describe("the schema:", () => {
    let parses = (raw: JSON.t) =>
      switch raw->S.parseOrThrow(~to=Money.schema) {
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

    testSync("accepts an amount with the currency's decimals", () =>
      expect(parses(money(10.5, "EUR")))->toBe(true)
    )
    testSync("accepts a whole amount", () => expect(parses(money(1000.0, "EUR")))->toBe(true))
    testSync("accepts a negative amount", () => expect(parses(money(-10.5, "EUR")))->toBe(true))

    // The check that needs both halves of the pair, which is why it sits on the
    // record and not on the amount.
    testSync("rejects an amount more precise than its currency", () =>
      expect(parses(money(10.555, "EUR")))->toBe(false)
    )
    testSync("rejects a decimal amount of a currency that has none", () =>
      expect(parses(money(10.5, "JPY")))->toBe(false)
    )
    testSync("and accepts the same figure where the currency allows it", () =>
      expect(parses(money(10.5, "EUR")))->toBe(true)
    )

    testSync("rejects a non-finite amount", () =>
      expect(Money.validate(~amount=Float.Constants.nan, ~currency=EUR)->Result.isOk)->toBe(false)
    )

    // Why `float` and not `int`: ReScript's `int` is int32, so an `int` amount
    // stops at 2,147,483,647. A framework money type that cannot express a €22M
    // total is not one.
    testSync("accepts an amount an int32 could not hold", () =>
      expect(parses(money(9_000_000_000.0, "EUR")))->toBe(true)
    )

    testSync("rejects an unknown currency code", () =>
      expect(parses(money(10.0, "QQQ")))->toBe(false)
    )
    testSync("rejects a currency the framework has not admitted", () =>
      expect(parses(money(10.0, "AED")))->toBe(false)
    )
    testSync("rejects a lower-case currency code", () =>
      expect(parses(money(10.0, "eur")))->toBe(false)
    )

    // The wire form is the ISO code, not the variant's ReScript spelling —
    // standard at the boundary, checked type in the domain.
    testSync("serializes the currency as its three-letter code", () =>
      expect(m(10.5, EUR)->Util_Sury.toJson(Money.schema))->toEqual(money(10.5, "EUR"))
    )
  })
})
