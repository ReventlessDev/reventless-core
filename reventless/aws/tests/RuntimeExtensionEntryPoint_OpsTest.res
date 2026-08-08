open JestGlobals

// The deployed half of the runtime extension seam: what a Lambda makes of the
// RUNTIME_EXTENSIONS env var `RuntimeEnvironment_Lambda.makeFromCodeAsset`
// writes, and what it does with the hooks the shell lifted off the modules it
// imported. The shell's `import()` is the one step not covered here — its types
// are unknowable at compile time, which is exactly why everything either side of
// it lives in the module under test.

let fullConfig = `{"modules":["@acme/tracing/src/Ext.res.mjs"],"runtimeKind":"Aggregate","component":"AllAggregatesCmdHandler","plugin":"Catalog","platform":"Shop"}`

let recordingHook = (label, into: array<string>): ReventlessCore.RuntimeExtension.coldStartHook =>
  (~runtimeKind, ~component, ~plugin, ~platform) =>
    into->Array.push(
      `${label}|${runtimeKind->ReventlessCore.ComponentType.toString}|${component}|${plugin->Option.getOr(
          "-",
        )}|${platform->Option.getOr("-")}`,
    )

describe("RuntimeExtensionEntryPoint_Ops.parseConfig", () => {
  testSync("reads the identity and module list makeFromCodeAsset writes", () => {
    switch RuntimeExtensionEntryPoint_Ops.parseConfig(Some(fullConfig)) {
    | None => fail("expected a parsed config")
    | Some(config) =>
      expect(config.modules)->toEqual(["@acme/tracing/src/Ext.res.mjs"])
      expect(config.runtimeKind)->toBe("Aggregate")
      expect(config.component)->toBe("AllAggregatesCmdHandler")
      expect(config.plugin)->toEqual(Some("Catalog"))
      expect(config.platform)->toEqual(Some("Shop"))
    }
  })

  testSync("platform-scope runtimes carry null plugin/platform", () => {
    let raw = `{"modules":["@acme/x/src/E.res.mjs"],"runtimeKind":"Heartbeat","component":"CatalogPluginHeartbeat","plugin":null,"platform":null}`
    switch RuntimeExtensionEntryPoint_Ops.parseConfig(Some(raw)) {
    | None => fail("expected a parsed config")
    | Some(config) =>
      expect(config.plugin)->toEqual(None)
      expect(config.platform)->toEqual(None)
    }
  })

  testSync("an absent env var is the default — no extensions registered", () => {
    expect(RuntimeExtensionEntryPoint_Ops.parseConfig(None)->Option.isNone)->toBe(true)
    expect(RuntimeExtensionEntryPoint_Ops.parseConfig(Some(""))->Option.isNone)->toBe(true)
  })

  testSync("a malformed or incomplete config never stops the runtime", () => {
    // Each of these would be a framework bug, not an extension one; the seam
    // reports and stands down rather than failing a runtime that can still serve.
    expect(RuntimeExtensionEntryPoint_Ops.parseConfig(Some("not json"))->Option.isNone)->toBe(true)
    expect(RuntimeExtensionEntryPoint_Ops.parseConfig(Some("[1,2]"))->Option.isNone)->toBe(true)
    expect(
      RuntimeExtensionEntryPoint_Ops.parseConfig(
        Some(`{"modules":["a"],"component":"X"}`),
      )->Option.isNone,
    )->toBe(true)
    expect(
      RuntimeExtensionEntryPoint_Ops.parseConfig(
        Some(`{"modules":[],"runtimeKind":"Aggregate","component":"X"}`),
      )->Option.isNone,
    )->toBe(true)
  })
})

describe("RuntimeExtensionEntryPoint_Ops.fire", () => {
  testSync("hands every hook the runtime's identity, in order", () => {
    let seen: array<string> = []
    let config = RuntimeExtensionEntryPoint_Ops.parseConfig(Some(fullConfig))->Option.getOrThrow

    RuntimeExtensionEntryPoint_Ops.fire(
      config,
      [recordingHook("tracing", seen), recordingHook("accounting", seen)],
    )

    expect(seen)->toEqual([
      "tracing|Aggregate|AllAggregatesCmdHandler|Catalog|Shop",
      "accounting|Aggregate|AllAggregatesCmdHandler|Catalog|Shop",
    ])
  })

  testSync("a throwing hook does not stop its siblings or the runtime", () => {
    let seen: array<string> = []
    let config = RuntimeExtensionEntryPoint_Ops.parseConfig(Some(fullConfig))->Option.getOrThrow
    let broken: ReventlessCore.RuntimeExtension.coldStartHook = (
      ~runtimeKind as _,
      ~component as _,
      ~plugin as _,
      ~platform as _,
    ) => JsError.throwWithMessage("extension blew up")

    RuntimeExtensionEntryPoint_Ops.fire(config, [broken, recordingHook("accounting", seen)])

    expect(seen)->toEqual(["accounting|Aggregate|AllAggregatesCmdHandler|Catalog|Shop"])
  })

  testSync("an unknown runtimeKind is skipped rather than guessed", () => {
    // Only reachable on a framework version skew between the deploy-time
    // ComponentType and the layer's. Firing under a guessed kind would silently
    // attach a kind-routing extension to the wrong runtime.
    let seen: array<string> = []
    let config = RuntimeExtensionEntryPoint_Ops.parseConfig(
      Some(`{"modules":["a"],"runtimeKind":"SomethingNewer","component":"X"}`),
    )->Option.getOrThrow

    RuntimeExtensionEntryPoint_Ops.fire(config, [recordingHook("tracing", seen)])

    expect(seen)->toEqual([])
  })
})
