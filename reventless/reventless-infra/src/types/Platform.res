// Platform module type — abstract factory interface for platform-agnostic component assembly.
//
// Lives in reventless-infra so application plugin assembly code can depend on
// reventless-infra. The concrete implementation in reventless-aws satisfies this type.
//
// Usage pattern:
//
//   // app/MyPlugin.res — imports reventless-infra
//   module Make = (Platform: ReventlessInfra.Platform.T) => {
//     module MyAggregate = Platform.Aggregate.Make(MySpec, MyBehavior, MyMappings)
//     module MyReadModel = Platform.ReadModel.Make(MyRmSpec, MyMappings)
//     // ...
//   }
//
//   // index.res — Composition Root; the only file that imports reventless-aws
//   module Platform = ReventlessAws.Platform.Make(Config)
//   module App = MyPlugin.Make(Platform)

/**
Abstract factory interface for creating Reventless components without coupling
application code to a specific infrastructure provider.

Inject a `Platform.T` module (e.g. `ReventlessAws.Platform.Make(Config)`) at
the composition root, and use its nested `Make` functors everywhere else.

@example
```rescript
// CatalogPlugin.res — depends on reventless-infra
module Make = (Platform: Platform.T) => {
  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    NoEventMappings.Make(Category),
  )
  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryMappings)
}

// index.res — the only file that imports reventless-aws
module Platform = ReventlessAws.Platform.Make(AwsConfig)
module App = CatalogPlugin.Make(Platform)
```
*/

// Type alias to avoid shadowing by the nested `module Api` inside Platform.T.
type apiComponent = Api.component

module type T = {
  /** Platform-specific API type (e.g. `Types.AppSync.api` for AWS, `unit` for in-memory). */
  type api

  /** Platform-specific role type (e.g. `Types.AppSync.role` for AWS, `unit` for in-memory). */
  type role

  /** Factory for event-sourced aggregate components. */
  module Aggregate: {
    module Make: (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: EventMapper.Mappings with module Target := Spec,
    ) => Aggregate.T with type api = api
  }

  /** Factory for read model (query-side projection) components. */
  module ReadModel: {
    module Make: (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ) => ReadModel.T with module Spec = Spec and type api = api and type role = role
  }

  /** Factory for extension point components. */
  module ExtensionPoint: {
    module Make: (
      Spec: ExtensionPointMapping.Spec,
      Mappings: ExtensionPoint.Mappings with module Spec := Spec,
    ) => ExtensionPoint.T
  }

  /** Factory for extension components (bidirectional EP↔aggregate bridges). */
  module Extension: {
    module Make: (
      Spec: ExtensionMapping.Spec,
      Mappings: ExtensionMapping.Mappings with module Spec := Spec,
    ) => Extension.T
  }

  /** Factory for task (background job / S3 trigger) components. */
  module Task: {
    module Make: (Spec: Task.Spec) => Task.T with module Spec = Spec
  }

  /** Ready-to-use counter component (no Make required). */
  module Counter: Counter.T

  /** Factory for DCB write-side state-change slice components. */
  module StateChangeSlice: {
    module Make: (Spec: Reventless.StateChangeSlice.Spec) => StateChangeSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec
  }

  /** Factory for DCB read-side state-view slice components. */
  module StateViewSlice: {
    module Make: (Spec: Reventless.StateViewSlice.Spec) => StateViewSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec
  }

  /** Factory for DCB event log components. */
  module DcbEventLog: {
    module Make: (Spec: Reventless.DcbEventLog.Spec) => DcbEventLog.T
      with module Spec = Spec
  }

  /** Factory for the API (GraphQL) component. */
  module Api: {
    module Make: (Config: {
      let baseFragment: Api.schemaFragment
    }) => Api.T
  }

  /** Factory for plugin deployment units. */
  module Plugin: Plugin.T with type api = api and type role = role

  /** Factory for the Core management instance. */
  module Core: Core.T with type api = api and type role = role

  /** Create a shared scheduler for Core and Plugin. */
  let makeScheduler: unit => Pulumi.Output.t<Scheduler.operations>

  /** Deploy a complete platform (schema stitching + stack exports). */
  let makePlatform: (
    ~api: apiComponent,
    ~core: Core.component,
    ~plugins: array<Plugin.component>,
  ) => unit
}
