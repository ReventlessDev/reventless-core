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
          {component: "AddProduct", field: "imageUrl", annotation: "productImages"},
          {component: "Products", field: "imageUrl", annotation: "productImages"},
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
// Each entry keeps its declaring sites as provenance, so when a capability
// disappears from this list, the diff says which change removed it.

let capabilities: array<ReventlessInfra.Platform.capability> = [
  // catalog: AddProduct.imageUrl → productImages
  // catalog: Products.imageUrl → productImages
  ObjectStore({plugin: "Catalog", store: "productImages"}),
]
`,
      ),
    )
  })

  // A capability with no `{plugin}.{store}` identity: one arm, its declaring
  // slices as comments, and no `field` to name in them. The key-splitting the
  // store arm does must not be reached — an unsplittable key is an error there.
  testSync("renders a capability entry as a bare arm with its declaring slices", () => {
    let geocoding: PlatformCodegen.pluginManifest = {
      pluginName: "ordering",
      manifest: {
        capabilities: [
          {
            kind: Geocoding,
            key: "Geocoding",
            declaredBy: [{component: "GeocodeCustomerAddress"}],
          },
        ],
      },
    }
    switch PlatformCodegen.render([catalogManifest, geocoding]) {
    | Ok(source) => {
        expect(source->String.includes("  // ordering: GeocodeCustomerAddress\n  Geocoding,"))->toBe(
          true,
        )
        expect(source->String.includes("ObjectStore({plugin: \"Catalog\""))->toBe(true)
      }
    | Error(_) => expect(true)->toBe(false)
    }
  })

  // Several slices, in one plugin or several, legitimately need one capability.
  testSync("two slices needing one capability collapse to one arm", () => {
    let needs = (~pluginName, ~component): PlatformCodegen.pluginManifest => {
      pluginName,
      manifest: {
        capabilities: [{kind: Geocoding, key: "Geocoding", declaredBy: [{component: component}]}],
      },
    }
    switch PlatformCodegen.render([
      needs(~pluginName="ordering", ~component="GeocodeCustomerAddress"),
      needs(~pluginName="dispatch", ~component="GeocodeDropOff"),
    ]) {
    | Ok(source) => {
        expect(source->String.split("  Geocoding,")->Array.length)->toBe(2)
        expect(source->String.includes("  // ordering: GeocodeCustomerAddress"))->toBe(true)
        expect(source->String.includes("  // dispatch: GeocodeDropOff"))->toBe(true)
      }
    | Error(_) => expect(true)->toBe(false)
    }
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
          entry(~key="Catalog.productImages", ~declaredBy=[{component: "PlaceOrder", field: "receiptUpload", annotation: "Catalog.productImages"}]),
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
          entry(~key="Catalog.z", ~declaredBy=[{component: "C", field: "upload", annotation: "z"}]),
          entry(~key="Catalog.a", ~declaredBy=[{component: "C", field: "attachment", annotation: "a"}]),
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
          entry(~key="branding.logos", ~declaredBy=[{component: "AttachInvoice", field: "logoUrl", annotation: "branding.logos"}]),
        ],
      },
    }
    switch PlatformCodegen.render([foreign]) {
    | Ok(source) => {
        expect(
          source->String.includes(`// catalog: AttachInvoice.logoUrl → branding.logos`),
        )->toBe(true)
        expect(
          source->String.includes(`ObjectStore({plugin: "branding", store: "logos"}),`),
        )->toBe(true)
      }
    | Error(_) => expect(true)->toBe(false)
    }
  })

  // The defect this replaced: the store was reconstructed by comparing
  // the deploy-manifest entry name with the key's registered-name prefix,
  // case-insensitively. A kebab-case entry name against a PascalCase registered
  // name is an ordinary pairing that the comparison misses, and the fallback
  // quoted the qualified key — a string in no source file, offered to a reader
  // as the thing to grep for.
  testSync("a kebab-case entry name still names the store as the field spells it", () => {
    let inspector: PlatformCodegen.pluginManifest = {
      pluginName: "platform-inspector",
      manifest: {
        capabilities: [
          entry(
            ~key="PlatformInspector.inspectorSnapshots",
            ~declaredBy=[
              {component: "SyncAlarmState", field: "urn", annotation: "inspectorSnapshots"},
            ],
          ),
        ],
      },
    }
    switch PlatformCodegen.render([inspector]) {
    | Ok(source) => {
        expect(
          source->String.includes(
            `// platform-inspector: SyncAlarmState.urn → inspectorSnapshots`,
          ),
        )->toBe(true)
        expect(source->String.includes(`→ PlatformInspector.`))->toBe(false)
      }
    | Error(_) => expect(true)->toBe(false)
    }
  })

  // A manifest emitted before the store was recorded. The comment still names
  // the field — its actual job — and makes no claim it cannot support.
  testSync("a site with no recorded store names the field and nothing more", () => {
    let legacy: PlatformCodegen.pluginManifest = {
      pluginName: "catalog",
      manifest: {
        capabilities: [
          entry(~key="Catalog.productImages", ~declaredBy=[{component: "AddProduct", field: "imageUrl"}]),
        ],
      },
    }
    switch PlatformCodegen.render([legacy]) {
    | Ok(source) => {
        expect(source->String.includes("// catalog: AddProduct.imageUrl"))->toBe(true)
        expect(source->String.includes("→"))->toBe(false)
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
          entry(~key="Ordering.receipts", ~declaredBy=[{component: "PlaceOrder", field: "receipt", annotation: "receipts"}]),
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
