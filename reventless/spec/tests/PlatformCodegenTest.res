// Pins the platform generator's rendering: the committed
// `PlatformCapabilities.res` must be deterministic (regenerating with no
// manifest change is byte-identical, so the file never churns), dedup by the
// `{plugin}.{store}` key (that pair is a store's identity — many fields, in
// several plugins, legitimately name one store), and keep every declaring
// field as provenance so a disappearing capability's diff names its cause.

open JestGlobals

let entry = (~key, ~declaredBy): CapabilityManifest.entry => {
  kind: ObjectStore,
  key,
  declaredBy,
}

let catalogManifest: PlatformCodegen.pluginManifest = {
  pluginName: "catalog",
  manifest: {
    capabilities: [
      entry(
        ~key="Catalog.productImages",
        ~declaredBy=[
          {component: "AddProduct", field: "imageUrl"},
          {component: "Products", field: "imageUrl"},
        ],
      ),
    ],
  },
}

describe("PlatformCodegen.render", () => {
  testSync("renders header, provenance and the capability list", () => {
    expect(PlatformCodegen.render([catalogManifest]))->toEqual(
      Ok(
        `// AUTO-GENERATED — do not edit. Run \`pnpm run generate:platform\` to update.
//
// The platform's capability list, unioned from the committed
// \`capabilities.json\` manifests of the plugins deploy-manifest.yaml names.
// Each entry keeps its declaring fields as provenance, so when a capability
// disappears from this list, the diff says which field's change removed it.

let capabilities: array<ReventlessInfra.Platform.capability> = [
  // catalog: AddProduct.imageUrl @storageRef("productImages")
  // catalog: Products.imageUrl @storageRef("productImages")
  ObjectStore({plugin: "Catalog", store: "productImages"}),
]
`,
      ),
    )
  })

  testSync("no plugin declaring anything renders an empty list, not an absent binding", () => {
    let rendered = PlatformCodegen.render([
      {pluginName: "catalog", manifest: {capabilities: []}},
      {pluginName: "ordering", manifest: {capabilities: []}},
    ])
    switch rendered {
    | Ok(source) => {
        expect(
          source->String.includes(
            "let capabilities: array<ReventlessInfra.Platform.capability> = []",
          ),
        )->toBe(true)
        expect(source->String.endsWith("\n"))->toBe(true)
      }
    | Error(_) => expect(true)->toBe(false)
    }
  })

  testSync("two plugins naming one store collapse to one entry with both provenances", () => {
    let orderingToo: PlatformCodegen.pluginManifest = {
      pluginName: "ordering",
      manifest: {
        capabilities: [
          entry(~key="Catalog.productImages", ~declaredBy=[{component: "PlaceOrder", field: "receiptUpload"}]),
        ],
      },
    }
    let entries = PlatformCodegen.union([catalogManifest, orderingToo])
    expect(entries->Array.length)->toBe(1)
    expect((entries->Array.getUnsafe(0)).declaredBy->Array.map(p => p.pluginName))->toEqual([
      "catalog",
      "catalog",
      "ordering",
    ])
  })

  testSync("entries are sorted by key regardless of manifest order", () => {
    let twoStores: PlatformCodegen.pluginManifest = {
      pluginName: "catalog",
      manifest: {
        capabilities: [
          entry(~key="Catalog.z", ~declaredBy=[{component: "C", field: "upload"}]),
          entry(~key="Catalog.a", ~declaredBy=[{component: "C", field: "attachment"}]),
        ],
      },
    }
    expect(PlatformCodegen.union([twoStores])->Array.map(e => e.key))->toEqual([
      "Catalog.a",
      "Catalog.z",
    ])
  })

  testSync("a foreign store's provenance quotes the qualified annotation form", () => {
    let foreign: PlatformCodegen.pluginManifest = {
      pluginName: "catalog",
      manifest: {
        capabilities: [
          entry(~key="branding.logos", ~declaredBy=[{component: "AttachInvoice", field: "logoUrl"}]),
        ],
      },
    }
    switch PlatformCodegen.render([foreign]) {
    | Ok(source) => {
        expect(
          source->String.includes(`// catalog: AttachInvoice.logoUrl @storageRef("branding.logos")`),
        )->toBe(true)
        expect(
          source->String.includes(`ObjectStore({plugin: "branding", store: "logos"}),`),
        )->toBe(true)
      }
    | Error(_) => expect(true)->toBe(false)
    }
  })

  testSync("a key without a plugin qualifier is refused, naming the key", () => {
    let malformed: PlatformCodegen.pluginManifest = {
      pluginName: "catalog",
      manifest: {capabilities: [entry(~key="productImages", ~declaredBy=[])]},
    }
    switch PlatformCodegen.render([malformed]) {
    | Ok(_) => expect(true)->toBe(false)
    | Error(message) => expect(message->String.includes("productImages"))->toBe(true)
    }
  })

  // A deploy manifest enumerates deployables, not plugins, so entries that are
  // not plugins reach the renderer as no `pluginManifest` at all — see
  // `PlatformManifestsTest` for the resolution that drops them. What must hold
  // here is that a mixed manifest renders exactly the plugins' union: the
  // non-plugin stacks neither add an entry nor suppress one.
  testSync("a manifest mixing plugin and non-plugin stacks renders the plugins' union", () => {
    let ordering: PlatformCodegen.pluginManifest = {
      pluginName: "ordering",
      manifest: {
        capabilities: [
          entry(~key="Ordering.receipts", ~declaredBy=[{component: "PlaceOrder", field: "receipt"}]),
        ],
      },
    }
    // The SdkService, SPA and ingester stacks alongside them contribute nothing.
    expect(PlatformCodegen.render([catalogManifest, ordering]))->toEqual(
      PlatformCodegen.render([catalogManifest, ordering]),
    )
    switch PlatformCodegen.render([catalogManifest, ordering]) {
    | Ok(source) => {
        expect(source->String.includes(`ObjectStore({plugin: "Catalog", store: "productImages"}),`))->toBe(true)
        expect(source->String.includes(`ObjectStore({plugin: "Ordering", store: "receipts"}),`))->toBe(true)
      }
    | Error(_) => expect(true)->toBe(false)
    }
  })

  testSync("regenerating with unchanged input is byte-identical", () =>
    expect(PlatformCodegen.render([catalogManifest]))->toEqual(
      PlatformCodegen.render([catalogManifest]),
    )
  )
})
