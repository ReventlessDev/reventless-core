let componentType = ComponentType.Plugin

type outputs = ReventlessInfra.Plugin.outputs

type t
type component = Component.t<t, outputs, unit>

// DCB spec for plugin-wide event/command types and state change slices.
// Aliased from ReventlessInfra so the DcbSpec module type is nominally identical
// across packages — this eliminates Obj.magic at the Platform boundary.
module type DcbSpec = ReventlessInfra.Plugin.DcbSpec

module type T = {
  type api
  type role
  let make: (
    ~name: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ReventlessInfra.ExtensionPoint.T)>=?,
    ~extensions: array<module(ReventlessInfra.Extension.T)>=?,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=?,
    ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = role)>=?,
    ~tasks: array<module(ReventlessInfra.Task.T)>=?,
    ~api: api,
    ~apiRole: role,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~dcbSpec: module(DcbSpec)=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let makeId = (name, version) => `${name}@${version}`
