open JestGlobals

// Two things are pinned here, and they fail for different reasons.
//
// The vocabulary ids are a string contract with a consumer in another repo that
// nothing type-checks across the boundary. A typo does not break a build; it
// makes a field render as a plain text box, which looks like the feature was
// never wired rather than like a one-character mistake. This is the side of the
// contract that can hold a test, so it holds one.
//
// The grammars are the reason these are types at all. An event log cannot be
// un-written, so a value the schema lets through is permanent — every rejection
// case below is a value that used to reach the log through a bare field.
describe("semantic scalars:", () => {
  describe("vocabulary ids match the wire strings:", () => {
    // Literals on purpose. Comparing the constant to itself would pass while the
    // contract was broken.
    testSync("email", () => expect(Semantic.Id.email)->toBe("email"))
    testSync("phone", () => expect(Semantic.Id.phone)->toBe("phone"))
    testSync("url", () => expect(Semantic.Id.url)->toBe("url"))
    testSync("percent", () => expect(Semantic.Id.percent)->toBe("percent"))
    testSync("bytes", () => expect(Semantic.Id.bytes)->toBe("bytes"))
    testSync("duration", () => expect(Semantic.Id.duration)->toBe("duration"))
    testSync("color", () => expect(Semantic.Id.color)->toBe("color"))
  })

  describe("every scalar marks itself:", () => {
    let carries = (schema, ~id) => schema->S.castToUnknown->Semantic.has(~id)

    testSync("email", () => expect(Email.schema->carries(~id="email"))->toBe(true))
    testSync("phone", () => expect(Phone.schema->carries(~id="phone"))->toBe(true))
    testSync("url", () => expect(Url.schema->carries(~id="url"))->toBe(true))
    testSync("percent", () => expect(Percent.schema->carries(~id="percent"))->toBe(true))
    testSync("bytes", () => expect(Bytes.schema->carries(~id="bytes"))->toBe(true))
    testSync("duration", () => expect(Duration.schema->carries(~id="duration"))->toBe(true))
    testSync("color", () => expect(Color.schema->carries(~id="color"))->toBe(true))

    // None of the seven is an entity reference, and none routes. A branded
    // scalar dragged into entity-id classification would be a routing failure,
    // which does not show up in a schema diff.
    testSync("and none of them is DCB-tagged or a reference", () =>
      expect(
        [
          Email.schema->S.castToUnknown,
          Phone.schema->S.castToUnknown,
          Url.schema->S.castToUnknown,
          Color.schema->S.castToUnknown,
        ]->Array.every(s => !DcbTag.isTagged(s) && Reference.getTarget(s)->Option.isNone),
      )->toBe(true)
    )
  })

  // An optional field's marker sits on the inner schema, because sury-ppx wraps
  // the annotated `string` rather than re-annotating the wrapper. Every reader
  // below went through `Semantic.get` and so read the wrapper and found nothing:
  // an optional `@storageRef` field left its object store undeclared, which is
  // an S3 bucket that never gets provisioned rather than a failing build.
  describe("an optional field keeps its semantic:", () => {
    let carries = (schema, ~id) => schema->S.castToUnknown->Semantic.has(~id)

    testSync("undefined-wrapped (the `field?: t` shape)", () =>
      expect(S.option(Email.schema)->carries(~id="email"))->toBe(true)
    )
    testSync("null-wrapped", () => expect(S.null(Url.schema)->carries(~id="url"))->toBe(true))

    testSync("an optional storage ref still declares its store", () =>
      expect(
        S.option(StorageRef.forStore(~store="productImages"))
        ->S.castToUnknown
        ->StorageRef.getStore
        ->Option.map(t => t.store),
      )->toEqual(Some("productImages"))
    )

    testSync("an optional reference still names its target", () =>
      expect(
        S.option(Reference.to_("Product"))
        ->S.castToUnknown
        ->Reference.getTarget
        ->Option.map(t => t.entity),
      )->toEqual(Some("Product"))
    )

    // The unwrap follows a union with one non-null variant — the shape an
    // optional field has. A real multi-variant union has no single inner schema
    // whose semantic could speak for the whole, so it stays unread.
    testSync("a multi-variant union carries no semantic of its own", () =>
      expect(S.union([Email.schema, Url.schema])->carries(~id="email"))->toBe(false)
    )
  })

  describe("Email:", () => {
    let accepts = raw => Email.fromString(raw)->Result.isOk

    testSync("accepts an address", () => expect(accepts("buyer@example.com"))->toBe(true))
    testSync("accepts subdomains and tags", () =>
      expect(accepts("first.last+orders@mail.example.co.uk"))->toBe(true)
    )
    testSync("rejects a bare word", () => expect(accepts("buyer"))->toBe(false))
    testSync("rejects a missing local part", () => expect(accepts("@example.com"))->toBe(false))
    testSync("rejects an embedded space", () => expect(accepts("a b@example.com"))->toBe(false))
    testSync("rejects the empty string", () => expect(accepts(""))->toBe(false))

    testSync("says what it wanted and shows the value", () =>
      expect(
        switch Email.fromString("buyer") {
        | Error(why) => why->String.includes("email address") && why->String.includes("buyer")
        | Ok(_) => false
        },
      )->toBe(true)
    )
  })

  describe("Url:", () => {
    let accepts = raw => Url.fromString(raw)->Result.isOk

    testSync("accepts https", () => expect(accepts("https://example.com/catalog"))->toBe(true))
    testSync("accepts http with a query", () =>
      expect(accepts("http://example.com/a?b=1"))->toBe(true)
    )
    testSync("accepts an uppercase scheme", () => expect(accepts("HTTPS://example.com"))->toBe(true))

    // The value of a field with this semantic is rendered as an anchor's href.
    // `new URL()` parses this happily, so the scheme check is the only thing
    // standing between a command and a permanently stored XSS.
    testSync("rejects javascript:", () => expect(accepts("javascript:alert(1)"))->toBe(false))
    testSync("rejects data:", () =>
      expect(accepts("data:text/html,<script>alert(1)</script>"))->toBe(false)
    )
    testSync("rejects mailto: — that is Email", () =>
      expect(accepts("mailto:buyer@example.com"))->toBe(false)
    )
    testSync("rejects a host with no scheme", () => expect(accepts("example.com"))->toBe(false))
    testSync("rejects a relative path", () => expect(accepts("/catalog/1"))->toBe(false))
    testSync("rejects the empty string", () => expect(accepts(""))->toBe(false))
  })

  describe("Phone:", () => {
    let accepts = raw => Phone.fromString(raw)->Result.isOk

    testSync("accepts an E.164 number", () => expect(accepts("+4930123456"))->toBe(true))
    testSync("accepts the shortest plausible number", () => expect(accepts("+1"))->toBe(true))
    testSync("accepts 15 digits", () => expect(accepts("+123456789012345"))->toBe(true))
    testSync("rejects 16 digits", () => expect(accepts("+1234567890123456"))->toBe(false))
    testSync("rejects a leading zero after the +", () => expect(accepts("+0301234"))->toBe(false))
    testSync("rejects a national form", () => expect(accepts("030 12 34 56"))->toBe(false))
    testSync("rejects punctuation", () => expect(accepts("+49-30-123456"))->toBe(false))
    testSync("rejects a missing +", () => expect(accepts("4930123456"))->toBe(false))
  })

  describe("Color:", () => {
    let accepts = raw => Color.fromString(raw)->Result.isOk

    testSync("accepts a six-digit triplet", () => expect(accepts("#1e90ff"))->toBe(true))
    testSync("accepts the shorthand", () => expect(accepts("#abc"))->toBe(true))
    testSync("accepts the shorthand with alpha", () => expect(accepts("#abcd"))->toBe(true))
    testSync("accepts eight digits", () => expect(accepts("#1e90ffcc"))->toBe(true))
    testSync("accepts uppercase digits", () => expect(accepts("#1E90FF"))->toBe(true))
    testSync("rejects a missing #", () => expect(accepts("1e90ff"))->toBe(false))
    testSync("rejects a five-digit length", () => expect(accepts("#1e90f"))->toBe(false))
    testSync("rejects a named colour", () => expect(accepts("rebeccapurple"))->toBe(false))

    // The swatch sets this value as a CSS `background`, where CSS accepts much
    // more than a colour.
    testSync("rejects a CSS function", () =>
      expect(accepts("url(https://evil.example/x.png)"))->toBe(false)
    )
  })

  describe("Percent:", () => {
    let accepts = n => Percent.fromFloat(n)->Result.isOk

    testSync("accepts zero", () => expect(accepts(0.0))->toBe(true))
    testSync("accepts a fraction of a percent", () => expect(accepts(99.95))->toBe(true))

    // The bound the unit decision turns on: 100 is the top of this scale, not
    // 100× the top of a 0–1 one.
    testSync("accepts 100", () => expect(accepts(100.0))->toBe(true))
    testSync("rejects 101", () => expect(accepts(101.0))->toBe(false))
    testSync("rejects a negative", () => expect(accepts(-0.5))->toBe(false))
    testSync("rejects NaN", () => expect(accepts(Float.Constants.nan))->toBe(false))
    testSync("rejects infinity", () => expect(accepts(Float.Constants.positiveInfinity))->toBe(false))

    testSync("names the scale it is not", () =>
      expect(
        switch Percent.fromFloat(101.0) {
        | Error(why) => why->String.includes("0–1")
        | Ok(_) => false
        },
      )->toBe(true)
    )
  })

  describe("Bytes:", () => {
    let accepts = n => Bytes.fromFloat(n)->Result.isOk

    testSync("accepts zero — an empty object has a size", () => expect(accepts(0.0))->toBe(true))
    testSync("accepts a small size", () => expect(accepts(1024.0))->toBe(true))

    // The case that decided the representation. int32 stops at 2,147,483,647,
    // so an `int` byte count could not express a 3 GB file.
    testSync("accepts a size above 2 GiB", () => expect(accepts(3_000_000_000.0))->toBe(true))
    testSync("accepts the largest exact integer", () =>
      expect(accepts(9007199254740991.0))->toBe(true)
    )
    testSync("rejects a negative", () => expect(accepts(-1.0))->toBe(false))
    testSync("rejects a fractional byte", () => expect(accepts(1.5))->toBe(false))
    testSync("rejects infinity", () => expect(accepts(Float.Constants.positiveInfinity))->toBe(false))
  })

  describe("Duration:", () => {
    let accepts = n => Duration.fromInt(n)->Result.isOk

    testSync("accepts zero — an instant timeout is a duration", () => expect(accepts(0))->toBe(true))
    testSync("accepts an hour and a minute in seconds", () => expect(accepts(3660))->toBe(true))
    testSync("rejects a negative", () => expect(accepts(-1))->toBe(false))

    testSync("says the unit it counts in", () =>
      expect(
        switch Duration.fromInt(-1) {
        | Error(why) => why->String.includes("seconds")
        | Ok(_) => false
        },
      )->toBe(true)
    )
  })

  // The schema and the constructor are one grammar by construction, and this is
  // the assertion that keeps it that way: whatever `fromString` rejects, the
  // schema rejects too. A second hand-rolled check would drift from this.
  describe("the schema agrees with the constructor:", () => {
    let parses = (schema, raw) =>
      switch raw->S.parseOrThrow(schema) {
      | _ => true
      | exception _ => false
      }

    testSync("Email", () =>
      expect((parses(Email.schema, "buyer@example.com"), parses(Email.schema, "buyer")))->toEqual((
        true,
        false,
      ))
    )
    testSync("Url", () =>
      expect((
        parses(Url.schema, "https://example.com"),
        parses(Url.schema, "javascript:alert(1)"),
      ))->toEqual((true, false))
    )
    testSync("Phone", () =>
      expect((parses(Phone.schema, "+4930123456"), parses(Phone.schema, "030 1234")))->toEqual((
        true,
        false,
      ))
    )
    testSync("Color", () =>
      expect((parses(Color.schema, "#1e90ff"), parses(Color.schema, "rebeccapurple")))->toEqual((
        true,
        false,
      ))
    )
    testSync("Percent", () =>
      expect((parses(Percent.schema, 42.5), parses(Percent.schema, 101.0)))->toEqual((true, false))
    )
    testSync("Bytes", () =>
      expect((parses(Bytes.schema, 3_000_000_000.0), parses(Bytes.schema, 1.5)))->toEqual((
        true,
        false,
      ))
    )
    testSync("Duration", () =>
      expect((parses(Duration.schema, 3660), parses(Duration.schema, -1)))->toEqual((true, false))
    )
  })
})
