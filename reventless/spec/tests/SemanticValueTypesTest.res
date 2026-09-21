// Drift guard for `Semantic.valueTypes` and the branded strings' `sample`.
//
// A tool writes these samples into scenarios, so each one has to compile and
// decode. The compile half is the fixtures below: one `let` per value type,
// holding its sample as source. The test reads this file back and checks each
// fixture against the list, so a sample that changes without its fixture fails
// here rather than in someone's generated test.

open JestGlobals

// Resolved from this module's own location; see `SemanticBrandedStringsTest`.
let here = NodePath.dirname(NodeUrl.fileURLToPath(NodeImportMeta.url))
let semanticDir = here ++ "/../src/semantic"
let ownSource = here ++ "/SemanticValueTypesTest.res"

// ── Fixtures: each `valueTypes` sample, without the `Reventless.` namespace ──
let sampleMoney = Money.make(~amount=1000.0, ~currency=Currency.EUR)
let sampleCurrency = Currency.EUR
let sampleDateRange = {DateRange.start: "2024-01-01T00:00:00Z", end_: "2024-01-02T00:00:00Z"}
let sampleGeoPoint = {GeoPoint.lat: 0.0, lng: 0.0}
let sampleCaptionedImage = {
  CaptionedImage.ref: "/example/example.png",
  altText: "An example image",
  caption: "An example caption",
}
let sampleDuration = 3600
let samplePercent = 50.0
let sampleBytes = 1024.0

/** Whitespace and the formatter's trailing commas removed, so a fixture the
    formatter wrapped still matches its one-line sample. */
let normalize = (source: string) =>
  source
  ->String.replaceRegExp(/\s+/g, "")
  ->String.replaceAll(",}", "}")
  ->String.replaceAll(",)", ")")

/** A value survives its schema: encoded, then parsed back, unchanged. */
let roundTrips = (value: 'a, schema: S.t<'a>): bool =>
  switch value->Util_Sury.toJson(schema)->Util_Sury.fromJson(schema) {
  | back => back == value
  | exception _ => false
  }

let isOk = result =>
  switch result {
  | Ok(_) => true
  | Error(_) => false
  }

let decodesValue: array<(string, unit => bool)> = [
  ("Money", () => roundTrips(sampleMoney, Money.schema)),
  ("Currency", () => roundTrips(sampleCurrency, Currency.schema)),
  (
    "DateRange",
    () =>
      roundTrips(sampleDateRange, DateRange.schema) &&
      DateRange.make(~start=sampleDateRange.start, ~end_=sampleDateRange.end_)->isOk,
  ),
  (
    "GeoPoint",
    () =>
      roundTrips(sampleGeoPoint, GeoPoint.schema) &&
      GeoPoint.make(~lat=sampleGeoPoint.lat, ~lng=sampleGeoPoint.lng)->isOk,
  ),
  (
    "CaptionedImage",
    () => roundTrips(sampleCaptionedImage, CaptionedImage.forField(~store="example")),
  ),
  ("Duration", () => roundTrips(sampleDuration, Duration.schema)),
  ("Percent", () => roundTrips(samplePercent, Percent.schema)),
  ("Bytes", () => roundTrips(sampleBytes, Bytes.schema)),
]

/** A raw string accepted by the schema and, where the module has one, by its
    `fromString`. A store or collection is needed where the schema takes one;
    any name does. */
let acceptsString = (raw: string, schema: S.t<string>, ~fromString=?) =>
  switch JSON.Encode.string(raw)->S.parseOrThrow(~to=schema) {
  | parsed =>
    parsed == raw &&
      switch fromString {
      | Some(check) => check(raw)->isOk
      | None => true
      }
  | exception _ => false
  }

let decodesString: array<(string, string => bool)> = [
  ("DateTime", raw => acceptsString(raw, DateTime.schema, ~fromString=DateTime.fromString)),
  (
    "CalendarDate",
    raw => acceptsString(raw, CalendarDate.schema, ~fromString=CalendarDate.fromString),
  ),
  ("Email", raw => acceptsString(raw, Email.schema, ~fromString=Email.fromString)),
  ("Phone", raw => acceptsString(raw, Phone.schema, ~fromString=Phone.fromString)),
  ("Url", raw => acceptsString(raw, Url.schema, ~fromString=Url.fromString)),
  ("Color", raw => acceptsString(raw, Color.schema, ~fromString=Color.fromString)),
  ("FileRef", raw => acceptsString(raw, FileRef.schema, ~fromString=FileRef.fromString)),
  ("ImageRef", raw => acceptsString(raw, ImageRef.schema, ~fromString=ImageRef.fromString)),
  ("MemberRef", raw => acceptsString(raw, MemberRef.of_(~field="example"))),
  (
    "StorageRef",
    raw =>
      acceptsString(raw, StorageRef.forStore(~store="example"), ~fromString=StorageRef.fromString),
  ),
  (
    "UploadableFile",
    raw =>
      acceptsString(
        raw,
        UploadableFile.forField(~store="example"),
        ~fromString=UploadableFile.fromString,
      ),
  ),
  (
    "UploadableImage",
    raw =>
      acceptsString(
        raw,
        UploadableImage.forField(~store="example"),
        ~fromString=UploadableImage.fromString,
      ),
  ),
]

/** Parts a module's sample does not fill: primitives, and a part that takes a
    value other than its module's sample (a range does not end where it starts). */
let partOverrides: array<((string, string), string)> = [
  (("Money", "amount"), "1000.0"),
  (("DateRange", "end_"), `"2024-01-02T00:00:00Z"`),
  (("GeoPoint", "lat"), "0.0"),
  (("GeoPoint", "lng"), "0.0"),
  (("CaptionedImage", "altText"), `"An example image"`),
  (("CaptionedImage", "caption"), `"An example caption"`),
]

let primitives = ["float", "int", "string"]

/** The source a tool would put in for one part: an override, else the sample of
    the module the part names. */
let partSource = (~moduleName, ~part, ~kind): option<string> =>
  switch partOverrides->Array.find(((key, _)) => key == (moduleName, part)) {
  | Some((_, source)) => Some(source)
  | None =>
    switch Semantic.valueTypes->Array.find(v => v.moduleName == kind) {
    | Some(v) => Some(v.sample)
    | None =>
      Semantic.brandedStrings
      ->Array.find(b => b.moduleName == kind)
      ->Option.map(b => b.sample->JSON.Encode.string->JSON.stringify)
    }
  }

/** The writer with every `$part` replaced; `None` when a part has no source. */
let written = (v: Semantic.valueType): option<string> =>
  switch v.shape {
  | Number(_) => Some(v.writer->String.replaceAll("$value", v.sample))
  | Codes({codes}) =>
    codes->Array.findMap(code => {
      let source = v.writer->String.replaceAll("$code", code)
      source == v.sample ? Some(source) : None
    })
  | Parts({parts}) =>
    parts->Array.reduce(Some(v.writer), (acc, (part, kind)) =>
      switch (acc, partSource(~moduleName=v.moduleName, ~part, ~kind)) {
      | (Some(source), Some(value)) => Some(source->String.replaceAll("$" ++ part, value))
      | _ => None
      }
    )
  }

let sorted = names => names->Array.toSorted(String.compare)

describe("Semantic.valueTypes", () => {
  testSync("every semantic/ module is classified exactly once", () => {
    let onDisk =
      NodeFs.readdirSync(semanticDir, {withFileTypes: true})
      ->Array.filterMap(
        entry => {
          let name = entry->NodeFs.direntName
          entry->NodeFs.isFile && name->String.endsWith(".res")
            ? Some(name->String.slice(~start=0, ~end=String.length(name) - 4))
            : None
        },
      )
      ->sorted
    let classified = Array.flat([
      Semantic.brandedStrings->Array.map(b => b.moduleName),
      Semantic.valueTypes->Array.map(v => v.moduleName),
      Semantic.valueTypesWithoutWriter,
      Semantic.nonValueModules,
    ])
    // Without this the comparison passes vacuously on an empty read.
    expect(onDisk->Array.length > 0)->toBe(true)
    expect(classified->sorted)->toEqual(onDisk)
  })

  testSync("every sample has a fixture in this file", () => {
    let source = NodeFs.readFileSync(ownSource)->normalize
    let missing = Semantic.valueTypes->Array.filter(
      v => {
        let fixture =
          `let sample${v.moduleName}=${v.sample->String.replaceAll("Reventless.", "")}`->normalize
        !(source->String.includes(fixture))
      },
    )
    expect(missing->Array.map(v => v.moduleName))->toEqual([])
  })

  testSync("every sample decodes through its module's schema", () => {
    expect(decodesValue->Array.map(((m, _)) => m)->sorted)->toEqual(
      Semantic.valueTypes->Array.map(v => v.moduleName)->sorted,
    )
    expect(
      decodesValue->Array.filter(((_, decodes)) => !decodes())->Array.map(((m, _)) => m),
    )->toEqual([])
  })

  testSync("every writer, filled with the sample's parts, is the sample", () => {
    expect(
      Semantic.valueTypes
      ->Array.filter(v => written(v) != Some(v.sample))
      ->Array.map(v => v.moduleName),
    )->toEqual([])
  })

  testSync("every part names a primitive or a semantic module", () => {
    let known = kind =>
      primitives->Array.includes(kind) ||
      Semantic.valueTypes->Array.some(v => v.moduleName == kind) ||
      Semantic.brandedStrings->Array.some(b => b.moduleName == kind)
    let unknown = Semantic.valueTypes->Array.flatMap(
      v =>
        switch v.shape {
        | Parts({parts}) => parts->Array.filter(((_, kind)) => !known(kind))
        | _ => []
        },
    )
    expect(unknown)->toEqual([])
  })

  testSync("a number's literal matches whether it is an integer", () => {
    expect(
      Semantic.valueTypes
      ->Array.filter(
        v =>
          switch v.shape {
          | Number({integer}) => integer == v.sample->String.includes(".")
          | _ => false
          },
      )
      ->Array.map(v => v.moduleName),
    )->toEqual([])
  })

  testSync("Currency's codes are the module's own", () => {
    let codes = Semantic.valueTypes->Array.findMap(
      v =>
        switch v.shape {
        | Codes({codes}) if v.moduleName == "Currency" => Some(codes)
        | _ => None
        },
    )
    expect(codes)->toEqual(Some(Currency.all->Array.map(Currency.toString)))
  })
})

describe("Semantic.brandedStrings samples", () => {
  testSync("every branded string has a decoder here", () => {
    expect(decodesString->Array.map(((m, _)) => m)->sorted)->toEqual(
      Semantic.brandedStrings->Array.map(b => b.moduleName)->sorted,
    )
  })

  testSync("every sample is accepted by its module", () => {
    let rejected = Semantic.brandedStrings->Array.filter(
      b =>
        switch decodesString->Array.find(((m, _)) => m == b.moduleName) {
        | Some((_, accepts)) => !accepts(b.sample)
        | None => true
        },
    )
    expect(rejected->Array.map(b => b.moduleName))->toEqual([])
  })
})
