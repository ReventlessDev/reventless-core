let componentType = ComponentType.Plugin

type outputs = ReventlessInfra.Plugin.outputs

type t
type component = Component.t<t, outputs, unit>

module type T = {
  type api
  type role
  let make: (
    ~name: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ReventlessInfra.ExtensionPoint.T)>=?,
    ~extensions: array<module(ReventlessInfra.Extension.Blueprint)>=?,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=?,
    ~readModels: array<
      module(ReventlessInfra.ReadModel.T with type api = api and type role = role),
    >=?,
    ~tasks: array<module(ReventlessInfra.Task.T)>=?,
    ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>=?,
    ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>=?,
    ~automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>=?,
    ~outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>=?,
    ~inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>=?,
    ~uiFragments: Reventless.Plugin.uiFragmentManifest=?,
    ~pluginStructure: Reventless.Plugin.pluginStructure=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
  let makeAutoUIManifest: (
    ~remoteEntryUrl: string,
    ~name: string,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>,
    ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = role)>,
    ~readModelPositions: array<string>=?,
    ~aggregatePositions: array<string>=?,
  ) => Reventless.Plugin.uiFragmentManifest
  let makePluginDefinition: (
    ~name: string,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=?,
    ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = role)>=?,
    ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>=?,
    ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>=?,
    ~automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>=?,
    ~outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>=?,
    ~inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>=?,
    ~extensions: array<module(ReventlessInfra.Extension.Blueprint)>=?,
  ) => Reventless.Plugin.pluginStructure
}

let makeId = (name, version) => `${name}@${version}`

// Inverse of `makeId` for the GraphQL boundary. Internally a plugin id is
// `name@version` so the in-memory platform's plugin store can key by it, but
// the platform invariant is one version per plugin at a time — so anything
// crossing into the UI (routes, federation remote name, subscription
// payloads) gets the bare name. If the input has no `@`, returns it as-is.
let name = (id: string): string =>
  id->String.split("@")->Array.get(0)->Option.getOr(id)
