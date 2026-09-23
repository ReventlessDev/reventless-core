open JestGlobals

describe("CertifyTrait.parseArgs", () => {
  // What `scripts/check-trait-pack.mjs` runs after a specimen's conformance suite.
  testSync("the trait, the host, the report and the certificate", () =>
    expect(
      CertifyTrait.parseArgs([
        "@reventlessdev/trait-address-geocoding",
        "--host",
        "Customer",
        "--report",
        "jest.json",
        "--out",
        "certificate.yaml",
      ]),
    )->toEqual(
      Ok({
        CertifyTrait.traitPackage: "@reventlessdev/trait-address-geocoding",
        host: "Customer",
        report: "jest.json",
        out: "certificate.yaml",
      }),
    )
  )

  testSync("the flags may come in any order", () =>
    expect(
      CertifyTrait.parseArgs(["t", "--out", "c.yaml", "--report", "r.json", "--host", "H"]),
    )->toEqual(Ok({CertifyTrait.traitPackage: "t", host: "H", report: "r.json", out: "c.yaml"}))
  )

  testSync("all three flags are required", () =>
    expect(CertifyTrait.parseArgs(["t", "--host", "H", "--report", "r.json"]))->toEqual(
      Error("--host, --report and --out are all required."),
    )
  )
})
