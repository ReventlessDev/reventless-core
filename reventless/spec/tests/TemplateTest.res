open JestGlobals

// The renderer composes text a person receives, so its two load-bearing
// properties are totality (it never throws) and withholding (a `@sensitive`
// field never reaches the output).

@schema
type lineItem = {name: string, quantity: int}

@schema
type order = {
  orderId: string,
  total: @s.matches(Money.schema) Money.t,
  taxRate: @s.matches(Percent.schema) float,
  packedSize: @s.matches(Bytes.schema) float,
  packingSeconds: @s.matches(Duration.schema) int,
  expedited: bool,
  note: string,
  customerEmail: @s.matches(Email.schema) string,
  couponCode: @s.matches(Sensitive.string) string,
  resetToken?: @s.matches(Sensitive.string) string,
  items: array<lineItem>,
}

@schema
type event =
  | OrderPlaced({orderId: string, couponCode: @s.matches(Sensitive.string) string})
  | OrderShipped({orderId: string})

let payload = JSON.parseOrThrow(`{
  "orderId": "o-1",
  "total": {"amount": 123450, "currency": "EUR"},
  "taxRate": 19.5,
  "packedSize": 1536,
  "packingSeconds": 3660,
  "expedited": true,
  "note": "",
  "customerEmail": "buyer@example.com",
  "couponCode": "SUMMER",
  "resetToken": "abc123",
  "items": [{"name": "Mug", "quantity": 2}, {"name": "Kettle", "quantity": 1}]
}`)

let render = source =>
  switch Template.renderSource(source, ~payload, ~schema=orderSchema) {
  | Ok(text) => text
  | Error(message) => `PARSE ERROR: ${message}`
  }

let parseError = source =>
  switch Template.parse(source) {
  | Ok(_) => "parsed"
  | Error(message) => message
  }

describe("Template:", () => {
  describe("parsing refuses what it cannot render:", () => {
    testSync("an opening brace with no closing one", () =>
      expect(parseError("Hello {{ orderId"))->toBe(`an opening "{{" with no closing "}}"`)
    )

    testSync("a block left open is named", () =>
      expect(parseError("{{# if expedited }}fast"))->toBe(
        `"{{# if expedited }}" was never closed`,
      )
    )

    testSync("a close that does not match what is open", () =>
      expect(parseError("{{# if expedited }}fast{{/ each }}"))->toBe(`"{{/ each }}" closes a "if"`)
    )

    testSync("a close with nothing open", () =>
      expect(parseError("done{{/ if }}"))->toBe(`a closing "{{/ if }}" with nothing open`)
    )

    // One level, so an item scope is always the item and never a guess.
    testSync("an each inside an each", () =>
      expect(parseError("{{# each items }}{{# each items }}x{{/ each }}{{/ each }}"))->toBe(
        `an "each" inside an "each" — iteration is one level deep`,
      )
    )

    testSync("an item-relative path where there is no item", () =>
      expect(parseError("{{ .name }}"))->toBe(
        `".name" is item-relative, and there is no item outside an "each"`,
      )
    )

    testSync("a formatter outside the vocabulary names the vocabulary", () =>
      expect(parseError("{{ total | dollars }}"))->toBe(
        `"dollars" is not a formatter — one of raw, money, percent, bytes, duration, dateRange, geoPoint`,
      )
    )

    testSync("a path that is not one", () =>
      expect(parseError("{{ order-id }}")->String.startsWith(`"order-id" is not a path`))->toBe(
        true,
      )
    )
  })

  describe("a value is formatted by its own semantic, with nothing in the template:", () => {
    testSync("money", () => expect(render("{{ total }}"))->toBe("1,234.50 EUR"))

    testSync("percent", () => expect(render("{{ taxRate }}"))->toBe("19.5%"))

    testSync("bytes", () => expect(render("{{ packedSize }}"))->toBe("1.5 KB"))

    testSync("duration", () => expect(render("{{ packingSeconds }}"))->toBe("1h 1m"))

    testSync("a field with no semantic is its plain value", () =>
      expect(render("Order {{ orderId }}."))->toBe("Order o-1.")
    )

    testSync("`| raw` renders what the payload holds", () =>
      expect(render("{{ total | raw }}"))->toBe(`{"amount":123450,"currency":"EUR"}`)
    )

    // A shaping that cannot apply falls back to the value: it is there, only the
    // formatter did not fit.
    testSync("an override that does not apply falls back to the value", () =>
      expect(render("{{ orderId | money }}"))->toBe("o-1")
    )
  })

  describe("a sensitive value never reaches the output:", () => {
    testSync("an annotated field is withheld", () =>
      expect(render("code {{ couponCode }}"))->toBe("code [withheld: couponCode]")
    )

    // The marker on an optional field sits inside sury's wrapper, and a walk
    // that read only the outer schema would leak it.
    testSync("an optional annotated field is withheld", () =>
      expect(render("{{ resetToken }}"))->toBe("[withheld: resetToken]")
    )

    testSync("an email is withheld with no annotation at all", () =>
      expect(render("{{ customerEmail }}"))->toBe("[withheld: customerEmail]")
    )

    // A guard renders no value, so it is allowed — refusing it would silently
    // drop the body.
    testSync("a guard on a sensitive field still renders its body", () =>
      expect(render("{{# if customerEmail }}we will email you{{/ if }}"))->toBe(
        "we will email you",
      )
    )

    testSync("one arm of an event union answers for its own fields", () =>
      expect(
        switch Template.variantSchema(eventSchema, ~variant="OrderPlaced") {
        | Some(arm) =>
          Template.renderSource(
            "{{ orderId }}/{{ couponCode }}",
            ~payload=JSON.parseOrThrow(`{"TAG":"OrderPlaced","orderId":"o-1","couponCode":"S"}`),
            ~schema=arm,
          )->Result.getOr("render error")
        | None => "no such arm"
        },
      )->toBe("o-1/[withheld: couponCode]")
    )
  })

  describe("an unresolved path is visible, never an exception:", () => {
    testSync("a field the payload does not have", () =>
      expect(render("{{ trackingNumber }}"))->toBe("[missing: trackingNumber]")
    )

    testSync("a path through a field that is not an object", () =>
      expect(render("{{ orderId.deeper }}"))->toBe("[missing: orderId.deeper]")
    )

    testSync("an each over something that is not a list", () =>
      expect(render("{{# each orderId }}x{{/ each }}"))->toBe("[missing: orderId]")
    )
  })

  describe("guards and iteration:", () => {
    testSync("a guard renders its body when the value is there", () =>
      expect(render("{{# if expedited }}Express.{{/ if }}"))->toBe("Express.")
    )

    testSync("an empty string is not a reason to render", () =>
      expect(render("{{# if note }}{{ note }}{{/ if }}done"))->toBe("done")
    )

    testSync("an absent field is not a reason to render", () =>
      expect(render("{{# if trackingNumber }}shipped{{/ if }}ok"))->toBe("ok")
    )

    testSync("each item is rendered with item-relative paths", () =>
      expect(render("{{# each items }}{{ .quantity }}x {{ .name }}; {{/ each }}"))->toBe(
        "2x Mug; 1x Kettle; ",
      )
    )

    testSync("the root is still reachable from inside an each", () =>
      expect(render("{{# each items }}{{ orderId }}:{{ .name }} {{/ each }}"))->toBe(
        "o-1:Mug o-1:Kettle ",
      )
    )

    testSync("an empty list renders nothing rather than a placeholder", () =>
      expect(
        Template.renderSource(
          "[{{# each items }}{{ .name }}{{/ each }}]",
          ~payload=JSON.parseOrThrow(`{"items": []}`),
          ~schema=orderSchema,
        )->Result.getOr("render error"),
      )->toBe("[]")
    )

    // Bounded, and it says so — a template rendered against an unexpected list
    // must not compose a message of unbounded length.
    testSync("iteration stops at the bound and says what it left", () => {
      let many = JSON.Encode.object(
        Dict.fromArray([
          (
            "items",
            JSON.Encode.array(
              Array.fromInitializer(~length=Template.maxItems + 3, _ =>
                JSON.Encode.object(Dict.fromArray([("name", JSON.Encode.string("x"))]))
              ),
            ),
          ),
        ]),
      )
      let out =
        Template.renderSource(
          "{{# each items }}{{ .name }}{{/ each }}",
          ~payload=many,
          ~schema=orderSchema,
        )->Result.getOr("render error")
      expect(out)->toBe(String.repeat("x", Template.maxItems) ++ "[… 3 more]")
    })
  })
})
