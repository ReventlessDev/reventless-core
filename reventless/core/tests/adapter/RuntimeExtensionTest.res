open JestGlobals

type call = {
  runtimeKind: ComponentType.t,
  component: string,
  plugin: option<string>,
  platform: option<string>,
}

let recorderNamed = (~companions: array<string>=[], label: string, into: array<(string, call)>): module(
  RuntimeExtension.Extension
) => {
  module R = {
    let moduleUrl = `file:///pkg/${label}.res.mjs`
    let companionModuleUrls = companions
    let onColdStart = (~runtimeKind, ~component, ~plugin, ~platform) =>
      into->Array.push((label, {runtimeKind, component, plugin, platform}))
  }
  module(R: RuntimeExtension.Extension)
}

let fireAggregate = () =>
  RuntimeExtension.notifyColdStart(
    ~runtimeKind=ComponentType.Aggregate,
    ~component="AllAggregatesCmdHandler",
    ~plugin=Some("Catalog"),
    ~platform=Some("Shop"),
  )

describe("RuntimeExtension", () => {
  beforeEach(() => RuntimeExtension.reset())

  testSync("empty registry is the default and notifyColdStart is silent", () => {
    expect(RuntimeExtension.isEmpty())->toBe(true)
    expect(RuntimeExtension.moduleUrls())->toEqual([])
    expect(RuntimeExtension.companionModuleUrls())->toEqual([])
    fireAggregate()
    expect(true)->toBe(true)
  })

  testSync("a registered extension receives the runtime's full identity", () => {
    let calls: array<(string, call)> = []
    RuntimeExtension.use(recorderNamed("tracing", calls))

    fireAggregate()

    expect(calls)->toEqual([
      (
        "tracing",
        {
          runtimeKind: ComponentType.Aggregate,
          component: "AllAggregatesCmdHandler",
          plugin: Some("Catalog"),
          platform: Some("Shop"),
        },
      ),
    ])
  })

  testSync("several extensions compose, in registration order", () => {
    let calls: array<(string, call)> = []
    RuntimeExtension.use(recorderNamed("tracing", calls))
    RuntimeExtension.use(recorderNamed("accounting", calls))

    fireAggregate()

    expect(calls->Array.map(((label, _)) => label))->toEqual(["tracing", "accounting"])
  })

  testSync("moduleUrls reports every registration, in order", () => {
    let calls: array<(string, call)> = []
    RuntimeExtension.use(recorderNamed("tracing", calls))
    RuntimeExtension.use(recorderNamed("accounting", calls))

    expect(RuntimeExtension.isEmpty())->toBe(false)
    expect(RuntimeExtension.moduleUrls())->toEqual([
      "file:///pkg/tracing.res.mjs",
      "file:///pkg/accounting.res.mjs",
    ])
  })

  testSync("companionModuleUrls flattens every registration's companions, in order", () => {
    let calls: array<(string, call)> = []
    RuntimeExtension.use(
      recorderNamed(
        ~companions=["file:///pkg/companion-a.res.mjs", "file:///pkg/companion-b.res.mjs"],
        "tracing",
        calls,
      ),
    )
    RuntimeExtension.use(recorderNamed("accounting", calls))
    RuntimeExtension.use(
      recorderNamed(~companions=["file:///pkg/companion-c.res.mjs"], "quota", calls),
    )

    expect(RuntimeExtension.companionModuleUrls())->toEqual([
      "file:///pkg/companion-a.res.mjs",
      "file:///pkg/companion-b.res.mjs",
      "file:///pkg/companion-c.res.mjs",
    ])
    // Companions are bundle-only: the entry shell's import list is untouched.
    expect(RuntimeExtension.moduleUrls())->toEqual([
      "file:///pkg/tracing.res.mjs",
      "file:///pkg/accounting.res.mjs",
      "file:///pkg/quota.res.mjs",
    ])
  })

  testSync("a throwing extension is skipped; the runtime and its siblings survive", () => {
    let calls: array<(string, call)> = []
    module Broken: RuntimeExtension.Extension = {
      let moduleUrl = "file:///pkg/broken.res.mjs"
      let companionModuleUrls = []
      let onColdStart = (~runtimeKind as _, ~component as _, ~plugin as _, ~platform as _) =>
        JsError.throwWithMessage("extension blew up")
    }
    RuntimeExtension.use(module(Broken: RuntimeExtension.Extension))
    RuntimeExtension.use(recorderNamed("accounting", calls))

    // Fails the test if the seam propagates: the acceptance criterion is that a
    // broken extension does not take the runtime down.
    fireAggregate()

    expect(calls->Array.map(((label, _)) => label))->toEqual(["accounting"])
  })

  testSync("notifyColdStartHooks fires loose hooks — the deployed runtime's path", () => {
    // A deployed entry point holds hooks lifted off dynamically imported
    // modules, not first-class modules, so it never populates this process's
    // registry. Same isolation and ordering apply.
    let seen: array<string> = []
    let hook = (label): RuntimeExtension.coldStartHook =>
      (~runtimeKind as _, ~component, ~plugin as _, ~platform as _) =>
        seen->Array.push(`${label}:${component}`)

    RuntimeExtension.notifyColdStartHooks(
      ~hooks=[hook("a"), hook("b")],
      ~runtimeKind=ComponentType.ReadModel,
      ~component="AllReadModels",
      ~plugin=None,
      ~platform=None,
    )

    expect(seen)->toEqual(["a:AllReadModels", "b:AllReadModels"])
  })

  testSync("reset clears the registry", () => {
    let calls: array<(string, call)> = []
    RuntimeExtension.use(recorderNamed("tracing", calls))
    RuntimeExtension.reset()

    fireAggregate()

    expect(RuntimeExtension.isEmpty())->toBe(true)
    expect(calls)->toEqual([])
  })
})
