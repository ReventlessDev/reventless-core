// Pins `Discovery.chapterOf` — the build-time derivation of a component's intra-plugin
// grouping band ("chapter") from its source path. The heuristic (first `src/`-relative
// directory segment that is not a recognised kind-folder) must reuse the single-source
// `ComponentKind.isKindFolder` so a chapter read here off disk agrees with a chapter
// reflected off the deployed plugin structure. See docs/plans/deployed-chapter-grouping.md.

open JestGlobals

module D = Discovery

describe("Discovery.chapterOf", () => {
  // A component nested under a chapter folder reports that folder as its chapter.
  testSync("src/<Chapter>/<Kind>/<Component>.res -> Some(<Chapter>)", () =>
    expect(D.chapterOf("Product/Aggregate/Product.res"))->toEqual(Some("Product"))
  )

  testSync("read model under a chapter folder", () =>
    expect(D.chapterOf("Product/ReadModel/Products.res"))->toEqual(Some("Product"))
  )

  testSync("DCB slice under a chapter folder", () =>
    expect(D.chapterOf("Order/StateChangeSlice/PlaceOrder.res"))->toEqual(Some("Order"))
  )

  // A component directly under a kind-folder carries no chapter.
  testSync("src/<Kind>/<Component>.res -> None", () =>
    expect(D.chapterOf("Aggregate/Product.res"))->toEqual(None)
  )

  testSync("plural / short kind-folder spelling is still a kind folder (no chapter)", () =>
    expect(D.chapterOf("StateChange/PlaceOrder.res"))->toEqual(None)
  )

  // An entity subfolder *under* a kind folder is not a chapter — the leading segment
  // is the kind folder, so there is no chapter.
  testSync("entity subfolder under a kind folder -> None", () =>
    expect(D.chapterOf("Aggregate/Product/Product.res"))->toEqual(None)
  )

  // A file at the src root has no directory segment, hence no chapter.
  testSync("file at src root -> None", () => expect(D.chapterOf("Plugin.res"))->toEqual(None))
})

describe("Discovery.chaptersByStem", () => {
  let files: array<D.discoveredFile> = [
    {stem: "Product", componentType: Aggregate, epGroup: None, relPath: "Product/Aggregate/Product.res"},
    {
      stem: "Product_Behavior",
      componentType: Aggregate,
      epGroup: None,
      relPath: "Product/Aggregate/Product_Behavior.res",
    },
    {stem: "Products", componentType: ReadModel, epGroup: None, relPath: "Product/ReadModel/Products.res"},
    {stem: "Category", componentType: Aggregate, epGroup: None, relPath: "Category/Aggregate/Category.res"},
    // Directly under a kind folder — no chapter, excluded from the map.
    {stem: "ImportProducts", componentType: Task, epGroup: None, relPath: "Task/ImportProducts.res"},
  ]

  testSync("maps every chaptered stem (incl. body files) to its chapter, sorted by stem", () =>
    expect(D.chaptersByStem(files))->toEqual([
      ("Category", "Category"),
      ("Product", "Product"),
      ("Product_Behavior", "Product"),
      ("Products", "Product"),
    ])
  )

  testSync("a component with no chapter is absent from the map", () =>
    expect(D.chaptersByStem(files)->Array.some(((stem, _)) => stem == "ImportProducts"))->toEqual(
      false,
    )
  )
})
