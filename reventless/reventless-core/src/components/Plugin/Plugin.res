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
    ~extensions: array<module(ReventlessInfra.Extension.T)>=?,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=?,
    ~readModels: array<
      module(ReventlessInfra.ReadModel.T with type api = api and type role = role),
    >=?,
    ~tasks: array<module(ReventlessInfra.Task.T)>=?,
    ~api: api,
    ~apiRole: role,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>=?,
    ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>=?,
    ~automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>=?,
    ~outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>=?,
    ~inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let makeId = (name, version) => `${name}@${version}`
