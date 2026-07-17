// The plugin.json `runtime` block (per-component memory/timeout) parses into
// Config.componentRuntime and is emitted by Codegen as a ~componentRuntime
// argument on Platform.Plugin.make. See
// docs/plans/configurable-component-runtime-resources.md.

open JestGlobals

describe("Config.getComponentRuntime", () => {
  testSync("parses a runtime block keyed by component name", () => {
    let json =
      `{"name":"Ordering","runtime":{"Customers":{"memorySize":2048},"Orders":{"memorySize":1024,"timeout":120}}}`->JSON.parseOrThrow
    let rt = Config.getComponentRuntime(json)
    expect(rt->Dict.get("Customers"))->toEqual(Some({Config.memorySize: Some(2048), timeout: None}))
    expect(rt->Dict.get("Orders"))->toEqual(Some({Config.memorySize: Some(1024), timeout: Some(120)}))
  })

  testSync("an absent runtime block yields an empty dict", () => {
    let json = `{"name":"Ordering"}`->JSON.parseOrThrow
    expect(Config.getComponentRuntime(json)->Dict.toArray)->toEqual([])
  })
})

describe("Codegen.renderComponentRuntimeParam", () => {
  testSync("emits nothing for an empty dict (byte-identical generated Plugin.res)", () => {
    expect(Codegen.renderComponentRuntimeParam(Dict.make()))->toEqual(None)
  })

  testSync("emits a Dict.fromArray entry with the record type qualified", () => {
    let rt = Dict.fromArray([("Customers", {Config.memorySize: Some(2048), timeout: None})])
    expect(Codegen.renderComponentRuntimeParam(rt))->toEqual(
      Some(
        `      ~componentRuntime=Dict.fromArray([("Customers", {ReventlessInfra.RuntimeHints.memorySize: Some(2048), timeout: None})]),`,
      ),
    )
  })

  testSync("renders both fields when a timeout override is present", () => {
    let rt = Dict.fromArray([("PlaceOrder", {Config.memorySize: Some(768), timeout: Some(60)})])
    expect(Codegen.renderComponentRuntimeParam(rt))->toEqual(
      Some(
        `      ~componentRuntime=Dict.fromArray([("PlaceOrder", {ReventlessInfra.RuntimeHints.memorySize: Some(768), timeout: Some(60)})]),`,
      ),
    )
  })
})
