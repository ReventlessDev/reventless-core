open JestGlobals

// `Money` is the first semantic type whose correctness is arithmetic rather
// than grammatical. A branded scalar is right when it rejects the values it
// should; this one is right when it *knows how precise an amount may be*, and it
// can only do that because the currency travels with the number.
//
// So the load-bearing currency below is JPY: it has no minor unit at all, where
// every other admitted code has two decimals. A suite that only exercises EUR
// proves nothing that a hardcoded `/100` would not also pass.
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

  describe("format places the decimal point from the currency:", () => {
    let format = (amount, currency) => Money.format(m(amount, currency))

    testSync("two decimals for EUR", () => expect(format(1000.0, EUR))->toBe("10.00 EUR"))

    // The case that decides whether the exponent is real or decorative.
    testSync("none for JPY", () => expect(format(1000.0, JPY))->toBe("1,000 JPY"))

    testSync("an amount under one unit keeps its leading zero", () =>
      expect(format(5.0, EUR))->toBe("0.05 EUR")
    )
    testSync("zero", () => expect(format(0.0, EUR))->toBe("0.00 EUR"))
    testSync("thousands are grouped", () =>
      expect(format(123456789.0, USD))->toBe("1,234,567.89 USD")
    )
    testSync("a refund is money", () => expect(format(-2550.0, EUR))->toBe("-25.50 EUR"))
  })

  // The boundary a form, a supplier feed or any other decimal-speaking caller
  // converts through. Nothing downstream of it holds a decimal.
  describe("ofMajor converts a decimal at the boundary:", () => {
    testSync("EUR scales by 100", () =>
      expect(Money.ofMajor(~amount=10.5, ~currency=EUR))->toEqual(m(1050.0, EUR))
    )

    // The reason this lives on the type rather than at each call site: written
    // by hand it is `*. 100.0`, which is wrong for this one.
    testSync("JPY scales by 1", () =>
      expect(Money.ofMajor(~amount=1000.0, ~currency=JPY))->toEqual(m(1000.0, JPY))
    )

    testSync("it rounds to a whole minor unit", () =>
      expect((
        Money.ofMajor(~amount=10.004, ~currency=EUR).amount,
        Money.ofMajor(~amount=10.006, ~currency=EUR).amount,
      ))->toEqual((1000.0, 1001.0))
    )

    // `Math.round` alone rounds half toward positive infinity, so a refund would
    // round the other way from the charge it reverses.
    testSync("a half rounds away from zero in both directions", () =>
      expect((
        Money.ofMajor(~amount=2.5, ~currency=JPY).amount,
        Money.ofMajor(~amount=-2.5, ~currency=JPY).amount,
      ))->toEqual((3.0, -3.0))
    )

    testSync("what it produces is always valid money", () =>
      expect(Money.validateAmount(Money.ofMajor(~amount=0.1 +. 0.2, ~currency=EUR).amount))
      ->toEqual(Ok(30.0))
    )

    testSync("toMajor is its inverse for a whole major amount", () =>
      expect(Money.toMajor(Money.ofMajor(~amount=1234.56, ~currency=EUR)))->toBe(1234.56)
    )

    testSync("and gives a form the figure it shows", () =>
      expect((Money.toMajor(m(1050.0, EUR)), Money.toMajor(m(1000.0, JPY))))->toEqual((10.5, 1000.0))
    )
  })

  describe("add checks the currency rather than assuming it:", () => {
    testSync("same currency adds", () =>
      expect(Money.add(m(100.0, EUR), m(50.0, EUR)))->toEqual(Ok(m(150.0, EUR)))
    )

    // §15.1's second rider. The branded-scalar shape would have made this
    // unrepresentable by deleting the currency; keeping it means the mix is
    // caught instead of silently summed into a meaningless number.
    testSync("different currencies do not", () =>
      expect(Money.add(m(100.0, EUR), m(50.0, USD))->Result.isOk)->toBe(false)
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
      expect(Money.add(m(10.0, EUR), m(20.0, EUR)))->toEqual(Ok(m(30.0, EUR)))
    )

    // The case that decided this representation: a decimal amount summed over a
    // page of rows lands a cent out and looks entirely plausible doing it.
    testSync("and it stays exact over a long run", () =>
      expect(Money.sum(Array.make(~length=10, m(10.0, EUR))))->toEqual(Some(Ok(m(100.0, EUR))))
    )

    testSync("sum refuses at the first currency that does not match", () =>
      expect(
        Money.sum([m(100.0, EUR), m(50.0, EUR), m(1.0, GBP)])->Option.map(Result.isOk),
      )->toEqual(Some(false))
    )

    testSync("the sum of no amounts has no currency to be in", () =>
      expect(Money.sum([])->Option.isNone)->toBe(true)
    )
  })

  // Quantity, not rate. The distinction is the whole reason this is exact: whole
  // minor units times a whole count needs no rounding decision, where a
  // percentage of an amount always does.
  describe("times multiplies by a count:", () => {
    testSync("a line item is its unit price times its quantity", () =>
      expect(Money.times(m(1050.0, EUR), ~by=3))->toEqual(Ok(m(3150.0, EUR)))
    )

    testSync("none of something is nothing, in the same currency", () =>
      expect(Money.times(m(1050.0, EUR), ~by=0))->toEqual(Ok(m(0.0, EUR)))
    )

    testSync("a negative count reverses the sign", () =>
      expect(Money.times(m(1050.0, EUR), ~by=-2))->toEqual(Ok(m(-2100.0, EUR)))
    )

    // No rounding is possible here, which is the point: the operands are whole
    // and so is everything they can produce.
    testSync("what it produces is always valid money", () =>
      expect(
        switch Money.times(m(333.0, EUR), ~by=7) {
        | Ok(product) => Money.validateAmount(product.amount)
        | Error(_) => Error("refused")
        },
      )->toEqual(Ok(2331.0))
    )

    // Past 2^53 a `float` stops being an exact integer, and every guarantee in
    // the module is stated over that range. Refused rather than quietly wrong.
    testSync("a product past the exact-integer range is refused", () =>
      expect(Money.times(m(9_000_000_000_000_000.0, EUR), ~by=3)->Result.isOk)->toBe(false)
    )

    testSync("and the refusal says what it could not stay inside", () =>
      expect(
        switch Money.times(m(9_000_000_000_000_000.0, EUR), ~by=3) {
        | Error(why) => why->String.includes("exact")
        | Ok(_) => false
        },
      )->toBe(true)
    )
  })

  // The last cent has to go somewhere, and the failure this prevents is the one
  // that looks like nothing: three shares of €3.33 are €9.99.
  describe("allocate splits an amount without losing a unit:", () => {
    let amounts = r => r->Result.getOr([])->Array.map(part => part.Money.amount)

    testSync("€10.00 into three is 3.34, 3.33, 3.33", () =>
      expect(amounts(Money.allocate(m(1000.0, EUR), ~into=3)))->toEqual([334.0, 333.0, 333.0])
    )

    testSync("and those add back up to what was split", () =>
      expect(
        Money.allocate(m(1000.0, EUR), ~into=3)->Result.getOr([])->Money.sum,
      )->toEqual(Some(Ok(m(1000.0, EUR))))
    )

    // The property, over sizes where the remainder lands differently each time.
    testSync("a split always adds back up to the whole", () =>
      expect(
        [1.0, 2.0, 7.0, 1000.0, 1001.0, 999999.0]->Array.every(amount =>
          [1, 2, 3, 7, 11]->Array.every(into =>
            Money.allocate(m(amount, EUR), ~into)->Result.getOr([])->Money.sum ==
              Some(Ok(m(amount, EUR)))
          )
        ),
      )->toBe(true)
    )

    testSync("every part is a whole minor unit", () =>
      expect(
        Money.allocate(m(1000.0, EUR), ~into=7)
        ->Result.getOr([])
        ->Array.every(part => Money.validateAmount(part.amount)->Result.isOk),
      )->toBe(true)
    )

    testSync("a split into one is the amount itself", () =>
      expect(amounts(Money.allocate(m(1000.0, EUR), ~into=1)))->toEqual([1000.0])
    )

    testSync("more parts than units leaves the tail at zero", () =>
      expect(amounts(Money.allocate(m(2.0, EUR), ~into=4)))->toEqual([1.0, 1.0, 0.0, 0.0])
    )

    // A refund divides like a charge: away from zero, and still summing back.
    testSync("a negative amount splits away from zero", () =>
      expect(amounts(Money.allocate(m(-1000.0, EUR), ~into=3)))->toEqual([
        -334.0,
        -333.0,
        -333.0,
      ])
    )

    // The currency that has no unit to hand out below the whole one.
    testSync("yen split three ways are whole yen", () =>
      expect(amounts(Money.allocate(m(10.0, JPY), ~into=3)))->toEqual([4.0, 3.0, 3.0])
    )

    testSync("a split into no parts at all is refused", () =>
      expect((
        Money.allocate(m(1000.0, EUR), ~into=0)->Result.isOk,
        Money.allocate(m(1000.0, EUR), ~into=-1)->Result.isOk,
      ))->toEqual((false, false))
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

    testSync("accepts an amount in minor units", () =>
      expect(parses(money(1000.0, "EUR")))->toBe(true)
    )
    testSync("accepts a negative amount", () => expect(parses(money(-1000.0, "EUR")))->toBe(true))

    // The check the type would have got for free from `int`, if `int` could
    // hold a real amount. Half a cent is not a value the log may contain.
    testSync("rejects a fraction of a minor unit", () =>
      expect(parses(money(10.5, "EUR")))->toBe(false)
    )
    testSync("rejects a non-finite amount", () =>
      expect(Money.validateAmount(Float.Constants.nan)->Result.isOk)->toBe(false)
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
    testSync("rejects a currency the framework has not admitted", () =>
      expect(parses(money(1000.0, "AED")))->toBe(false)
    )
    testSync("rejects a lower-case currency code", () =>
      expect(parses(money(1000.0, "eur")))->toBe(false)
    )

    // The wire form is the ISO code, not the variant's ReScript spelling —
    // standard at the boundary, checked type in the domain.
    testSync("serializes the currency as its three-letter code", () =>
      expect(m(1000.0, EUR)->Util_Sury.toJson(Money.schema))->toEqual(money(1000.0, "EUR"))
    )
  })
})
