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
  ?epGroup,
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
        Pairing.group: "Catalog.Products",
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
        Pairing.group: "G",
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
        Pairing.group: ?None,
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
      {Pairing.group: ?None, mappings: ["Flat_ExtensionPointMapping"]},
      {
        Pairing.group: "Grp",
        mappings: ["G1_ExtensionPointMapping", "G2_ExtensionPointMapping"],
      },
    ])
  })

  testSync("no EP files yields no extension points", () =>
    expect(Pairing.groupExtensionPoints([]))->toEqual([])
  )
})

let file = (~stem, ~componentType, ~relPath): Discovery.discoveredFile => {
  stem,
  componentType,
  relPath,
}

describe("Pairing.retiredBehaviorFile", () => {
  testSync("a slice's _Behavior file beside its spec is found", () =>
    expect(
      Pairing.retiredBehaviorFile([
        file(
          ~stem="AddProduct",
          ~componentType=StateChangeSlice,
          ~relPath="StateChange/AddProduct.res",
        ),
        file(
          ~stem="AddProduct_Behavior",
          ~componentType=StateChangeSlice,
          ~relPath="StateChange/AddProduct_Behavior.res",
        ),
      ])->Option.map(f => f.relPath),
    )->toEqual(Some("StateChange/AddProduct_Behavior.res"))
  )

  testSync("an aggregate's bare <Spec>Behavior file beside its spec is found", () =>
    expect(
      Pairing.retiredBehaviorFile([
        file(~stem="Product", ~componentType=Aggregate, ~relPath="Aggregate/Product.res"),
        file(
          ~stem="ProductBehavior",
          ~componentType=Aggregate,
          ~relPath="Aggregate/ProductBehavior.res",
        ),
      ])->Option.map(f => f.relPath),
    )->toEqual(Some("Aggregate/ProductBehavior.res"))
  )

  testSync("the renamed tree has none", () =>
    expect(
      Pairing.retiredBehaviorFile([
        file(~stem="Product", ~componentType=Aggregate, ~relPath="Aggregate/Product.res"),
        file(
          ~stem="Product_Decision",
          ~componentType=Aggregate,
          ~relPath="Aggregate/Product_Decision.res",
        ),
      ]),
    )->toEqual(None)
  )

  testSync("resolve refuses it, naming the new file and the codemod", () => {
    let message = try {
      let _ = Pairing.resolve(
        [
          file(
            ~stem="AddProduct",
            ~componentType=StateChangeSlice,
            ~relPath="StateChange/AddProduct.res",
          ),
          file(
            ~stem="AddProduct_Behavior",
            ~componentType=StateChangeSlice,
            ~relPath="StateChange/AddProduct_Behavior.res",
          ),
        ],
        ~srcDir="/no/such/src",
      )
      ""
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("")
    }
    expect((
      message->String.includes("AddProduct_Decision.res"),
      message->String.includes("reventless-rename-to-decision"),
    ))->toEqual((true, true))
  })
})

// The generator reads a few values straight off source lines, so a quote in a
// trailing comment must not be read as the value.
describe("Pairing.codeOf", () => {
  testSync("drops a trailing comment", () =>
    expect(
      Pairing.codeOf(`let targetName = None // or Some("Slice") when a command goes back`),
    )->toBe("let targetName = None")
  )

  testSync("keeps a // inside a string literal", () =>
    expect(Pairing.codeOf(`let targetName = "a//b" // note`))->toBe(`let targetName = "a//b"`)
  )

  testSync("keeps an escaped quote inside a string literal", () =>
    expect(
      Pairing.codeOf(`let x = "say \\"hi\\" // not a comment"`),
    )->toBe(`let x = "say \\"hi\\" // not a comment"`)
  )

  testSync("leaves a line with no comment alone", () =>
    expect(
      Pairing.codeOf(`let targetName = Some("Orders")`),
    )->toBe(`let targetName = Some("Orders")`)
  )
})

describe("Pairing.extractTargetName", () => {
  let read = text => {
    let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "target-name-"]))
    let path = NodePath.join([dir, "Spec.res"])
    NodeFs.writeFileSync(path, text)
    let found = Pairing.extractTargetName(path)
    NodeFs.rmSync(dir, {recursive: true, force: true})
    found
  }

  testSync("a quote in a trailing comment is not a target", () =>
    expect(read(`let targetName = None // or Some("Slice") when a command goes back`))->toEqual(
      None,
    )
  )

  testSync("a target followed by a comment is still read", () =>
    expect(read(`let targetName = Some("Orders") // the ledger`))->toEqual(Some("Orders"))
  )
})
