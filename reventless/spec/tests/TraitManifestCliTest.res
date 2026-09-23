open JestGlobals

describe("TraitManifestCli.parseArgs", () => {
  // What `scripts/check-trait-pack.mjs` runs against every packed trait.
  testSync("the trait and where to write its manifest", () =>
    expect(
      TraitManifestCli.parseArgs(["@reventlessdev/trait-attachments", "--out", "trait.yaml"]),
    )->toEqual(
      Ok({TraitManifestCli.traitPackage: "@reventlessdev/trait-attachments", out: "trait.yaml"}),
    )
  )

  testSync("--out is required", () =>
    expect(TraitManifestCli.parseArgs(["@reventlessdev/trait-attachments"]))->toEqual(
      Error("--out is required."),
    )
  )
})
