// Inert runtime arguments shared by the Delegate / Flow GWT DSLs.
//
// ExtensionPoint mappings and Extension delegates are pure translations, but
// their user-level functions take infrastructure handles (a query engine, a
// scheduler, message metadata, the plugin definition). The GWT runs them with
// these no-op stubs so the translation logic is exercised without any real
// infrastructure. See `docs/plans/done/gwt-flow-and-extension-test-kinds.md` Phase 0.

// No-op QueryEngine — any DB lookup resolves to empty results. Kept identical
// to the inline stub `Mapping_GWT` defines.
let queryEngine: Reventless.QueryEngine.operations = {
  scan: (~readModelName as _, ~filterConfigs as _, ~limit as _) => []->Promise.resolve,
  query: (
    ~readModelName as _: string,
    ~key as _: option<string>=?,
    ~id as _: Reventless.QueryEngine.value,
    ~subIdConfig as _: option<Reventless.QueryEngine.SubId.config>=?,
    ~filterConfigs as _: option<array<Reventless.QueryEngine.Filter.config>>=?,
    ~ascending as _: option<bool>=?,
    ~limit as _: option<int>=?,
  ) => []->Promise.resolve,
}

// Scheduler stubs — `create` / `delete` are inert. EP/Extension `Call`
// directives receive these as the side-effect handles they never act on.
let createSchedule: Reventless.Schedule.create = _schedule => Promise.resolve()
let deleteSchedule: Reventless.Schedule.delete = _name => Promise.resolve()

// Default message metadata threaded into the user-level mapping functions.
let meta: Reventless.Message.meta = {
  service: "gwt",
  time: "1970-01-01T00:00:00Z",
  msgId: "gwt-msg",
  correlationId: "gwt-corr",
}

// Minimal plugin definition — Extension delegates receive it as an inert arg.
// Mirrors the `fakePluginDefinition` the platform admin uses for its internal
// callback wiring.
let pluginDefinition: Reventless.Plugin.pluginDefinition = {
  id: "Gwt@TEST",
  name: "Gwt",
  version: "TEST",
  extensionPoints: [],
  extensions: [],
  eventCollector: "NOT-SET",
  extensionProtocols: [],
  apiSchemaFragment: None,
  apiTarget: None,
  structure: None,
  dcbEventLog: None,
  kind: Domain,
}
