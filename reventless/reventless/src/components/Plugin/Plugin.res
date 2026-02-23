let componentType = ComponentType.Plugin

type outputs = ReventlessSpec.Plugin.outputs

type t
type component = Component.t<t, outputs, unit>

// DCB spec for plugin-wide event/command types and state change slices
// Bundled together so the event type is shared between the DcbEventLog and all StateChangeSlices
module type DcbSpec = {
  @schema
  type event

  let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
  let stateViewSlices: array<module(StateViewSlice.T with type dcbEvent = event)>
}

module type T = {
  type api
  type role
  let make: (
    ~name: string,
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ReventlessSpec.ExtensionPoint.T)>=?,
    ~extensions: array<module(ReventlessSpec.Extension.T)>=?,
    ~aggregates: array<module(ReventlessSpec.Aggregate.T with type api = api)>=?,
    ~readModels: array<module(ReventlessSpec.ReadModel.T with type api = api and type role = role)>=?,
    ~tasks: array<module(ReventlessSpec.Task.T)>=?,
    ~api: api,
    ~apiRole: role,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~dcbSpec: module(DcbSpec)=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let makeId = (name, version) => `${name}@${version}`
