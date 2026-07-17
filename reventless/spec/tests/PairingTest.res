// Regression tests for the A8 grouped-ExtensionPoint bug in the plugin
// generator. `Pairing.groupExtensionPoints` (extracted from `resolve` to be
// I/O-free and testable) partitions EP mapping files into grouped + flat
// `extensionPointDef`s. The bug: `Option.getOr`'s eager default re-created a
// fresh empty array every iteration, so a group with ≥2 mappings collapsed to
// `[]` and the generator emitted a `Plugin.res` referencing a never-generated
// module. The first case is the exact reproduction.

open JestGlobals

let epFile = (~stem, ~epGroup): Discovery.discoveredFile => {
  stem,
  componentType: ExtensionPoint,
  epGroup,
  relPath: stem ++ ".res",
}

describe("Pairing.groupExtensionPoints", () => {
  testSync("a group with two mappings keeps BOTH (the A8 fix — no collapse to empty)", () => {
    let eps = Pairing.groupExtensionPoints([
      epFile(~stem="A_ExtensionPointMapping", ~epGroup=Some("Catalog.Products")),
      epFile(~stem="B_ExtensionPointMapping", ~epGroup=Some("Catalog.Products")),
    ])
    expect(eps)->toEqual([
      {
        Pairing.group: Some("Catalog.Products"),
        mappings: ["A_ExtensionPointMapping", "B_ExtensionPointMapping"],
      },
    ])
  })

  testSync("a group's mappings are sorted deterministically", () => {
    let eps = Pairing.groupExtensionPoints([
      epFile(~stem="Zeta_ExtensionPointMapping", ~epGroup=Some("G")),
      epFile(~stem="Alpha_ExtensionPointMapping", ~epGroup=Some("G")),
    ])
    expect(eps)->toEqual([
      {
        Pairing.group: Some("G"),
        mappings: ["Alpha_ExtensionPointMapping", "Zeta_ExtensionPointMapping"],
      },
    ])
  })

  testSync("ungrouped mappings collect into a single flat (group: None) entry", () => {
    let eps = Pairing.groupExtensionPoints([
      epFile(~stem="Solo_ExtensionPointMapping", ~epGroup=None),
      epFile(~stem="Other_ExtensionPointMapping", ~epGroup=None),
    ])
    expect(eps)->toEqual([
      {
        Pairing.group: None,
        mappings: ["Other_ExtensionPointMapping", "Solo_ExtensionPointMapping"],
      },
    ])
  })

  testSync("flat and grouped entries coexist", () => {
    let eps = Pairing.groupExtensionPoints([
      epFile(~stem="Flat_ExtensionPointMapping", ~epGroup=None),
      epFile(~stem="G1_ExtensionPointMapping", ~epGroup=Some("Grp")),
      epFile(~stem="G2_ExtensionPointMapping", ~epGroup=Some("Grp")),
    ])
    expect(eps)->toEqual([
      {Pairing.group: None, mappings: ["Flat_ExtensionPointMapping"]},
      {Pairing.group: Some("Grp"), mappings: ["G1_ExtensionPointMapping", "G2_ExtensionPointMapping"]},
    ])
  })

  testSync("no EP files yields no extension points", () =>
    expect(Pairing.groupExtensionPoints([]))->toEqual([])
  )
})
