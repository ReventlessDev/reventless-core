// Core module type — abstract factory interface for the Core management instance.
//
// Lives in reventless-infra alongside Plugin.T so Platform.T can reference both
// without depending on reventless-core.
//
// Core aggregates all platform extension points, aggregates, and read models
// into a single management deployment unit.

type outputs = {
  version: string,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  extensionPoints: Pulumi.Output.t<dict<ExtensionPoint.outputs>>,
  aggregates: Pulumi.Output.t<dict<Aggregate.outputs>>,
  readModels: dict<ReadModel.outputs>,
  api?: Api.component,
}

type t
type component = Component.t<t, outputs, unit>

/**
Module type for the Core management instance factory.

Call `Core.T.make` to provision all core components (extension points, aggregates,
read models, cloner, API) in a single Pulumi stack update.
*/
module type T = {
  type api
  type role
  type component
  let make: (
    ~version: string,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~aggregates: array<module(Aggregate.T with type api = api)>,
    ~readModels: array<module(ReadModel.T with type api = api and type role = role)>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~api: api,
    ~apiRole: role,
    ~resourceNaming: ResourceNaming.operations,
    ~apiComponent: Api.component=?,
  ) => component
}
