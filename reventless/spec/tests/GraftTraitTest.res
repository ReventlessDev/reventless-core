open JestGlobals

describe("GraftTrait.parseArgs", () => {
  // The address-geocoding specimen's graft, as `scripts/check-trait-pack.mjs`
  // runs it: every flag that is not the tool's own is a field of the trait's
  // config, and a value may contain spaces and quotes.
  testSync("the specimen graft: the tool's flags, then the trait's config", () =>
    expect(
      GraftTrait.parseArgs([
        "@reventlessdev/trait-address-geocoding",
        "--into",
        "src/Customer",
        "--tests",
        "tests/Customer",
        "--entity",
        "Customer",
        "--createdFields",
        "email: string",
        "--createdValues",
        `email: "alice@x.y"`,
      ]),
    )->toEqual(
      Ok({
        GraftTrait.traitPackage: "@reventlessdev/trait-address-geocoding",
        into: "src/Customer",
        tests: "tests/Customer",
        dryRun: false,
        fields: Dict.fromArray([
          ("entity", JSON.Encode.string("Customer")),
          ("createdFields", JSON.Encode.string("email: string")),
          ("createdValues", JSON.Encode.string(`email: "alice@x.y"`)),
        ]),
      }),
    )
  )

  // A key given no value is `true`, so the trait's schema can read it as a
  // boolean without the tool knowing which keys are flags.
  testSync("a key with no value is true, and --dry-run is the tool's own", () =>
    expect(
      GraftTrait.parseArgs([
        "t",
        "--into",
        "src",
        "--tests",
        "tests",
        "--dry-run",
        "--primary",
        "--cardinality",
        "bounded",
      ]),
    )->toEqual(
      Ok({
        GraftTrait.traitPackage: "t",
        into: "src",
        tests: "tests",
        dryRun: true,
        fields: Dict.fromArray([
          ("primary", JSON.Encode.bool(true)),
          ("cardinality", JSON.Encode.string("bounded")),
        ]),
      }),
    )
  )

  testSync("--into and --tests are required", () =>
    expect(GraftTrait.parseArgs(["t", "--into", "src"]))->toEqual(
      Error("--into and --tests are both required."),
    )
  )
})
