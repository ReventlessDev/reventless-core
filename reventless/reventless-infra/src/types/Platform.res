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

// Type alias for admin extension points dict — defined at file scope so it
// remains accessible inside module type T even though T re-declares
// `module ExtensionPoint` with a different local type, which would otherwise
// shadow the package-level ExtensionPoint.outputs.
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

// Type alias so `deployPlugin` can reference `Plugin.outputs` inside module type T,
// where `module Plugin: Plugin.T` shadows the package-level Plugin module.
type pluginOutputs = Plugin.outputs

module type T = {
  /** Platform-specific API type (e.g. `Types.AppSync.api` for AWS, `unit` for in-memory). */
  type api

  /** Platform-specific role type (e.g. `Types.AppSync.role` for AWS, `unit` for in-memory). */
  type role

  /** The platform's API instance — used by bundled DCB slice builders that need
      to create QueryDb resolvers inside the Platform functor. */
  let api: api

  /** The platform's API role instance — used alongside `api` for QueryDb resolvers. */
  let apiRole: role

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

  /** Factory for extension point components (single mapping). */
  module ExtensionPoint: {
    module Make: (
      Mapping: ExtensionPointMapping.Mapping,
      Config: {let moduleUrl: string},
    ) => ExtensionPoint.T

    /** Two-mapping variant — merges per-slice EP mappings. */
    module Make2: (
      Mapping1: ExtensionPointMapping.Mapping,
      Mapping2: ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
      Config: {let moduleUrl: string},
    ) => ExtensionPoint.T

    /** Three-mapping variant — merges per-slice EP mappings. */
    module Make3: (
      Mapping1: ExtensionPointMapping.Mapping,
      Mapping2: ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
      Mapping3: ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
      Config: {let moduleUrl: string},
    ) => ExtensionPoint.T

    /** Multi-mapping variant with full control over name and mappings array. */
    module MakeMulti: (
      Spec: ExtensionPointMapping.Spec,
      Mappings: ExtensionPoint.Mappings with module Spec := Spec,
    ) => ExtensionPoint.T
  }

  /** Factory for extension blueprints (single mapping).
      Returns a blueprint — not a built component. `Plugin.make` builds it,
      using the plugin name for the extension's component name and auto-merging
      blueprints that target the same extension point. */
  module Extension: {
    module Make: (
      Mapping: ExtensionMapping.Mapping,
    ) => Extension.Blueprint
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
      with module Spec = Spec
  }

  /** Factory for DCB read-side state-view slice components. */
  module StateViewSlice: {
    module Make: (Spec: Reventless.StateViewSlice.Spec) => StateViewSlice.T
      with module Spec = Spec
  }

  /** Factory for DCB automation slice components (TODO list pattern). */
  module AutomationSlice: {
    module Make: (Spec: Reventless.AutomationSlice.Spec) => AutomationSlice.T
      with module Spec = Spec
  }

  /** Factory for DCB outbound translation slice components (tracked external calls). */
  module OutboundTranslationSlice: {
    module Make: (Spec: Reventless.OutboundTranslationSlice.Spec) => OutboundTranslationSlice.T
      with module Spec = Spec
  }

  /** Factory for DCB inbound translation slice components (external input to commands). */
  module InboundTranslationSlice: {
    module Make: (Spec: Reventless.InboundTranslationSlice.Spec) => InboundTranslationSlice.T
      with module Spec = Spec
  }

  /** Factory for the API (GraphQL) component. */
  module Api: {
    module Make: (Config: {
      let baseFragment: Api.schemaFragment
    }) => Api.T
  }

  /** Whether this platform supports MCP (Model Context Protocol) for AI agent access.
      In-memory: starts an MCP server alongside GraphQL in makePlatform.
      AWS: deploys a Lambda Function URL with Streamable HTTP transport. */
  type mcpSupported = | @as(true) McpSupported | @as(false) McpNotSupported
  let mcpSupported: mcpSupported

  /** Factory for plugin deployment units. */
  module Plugin: Plugin.T with type api = api and type role = role

  /** Module type for plugin assembly — matches the `make` function produced by
      every plugin's `Make` functor. Pass first-class modules to `makePlatform`. */
  module type PluginMaker = {
    let make: unit => Plugin.component
  }

  /** Deploy a complete platform: creates the scheduler, builds each plugin,
      creates admin components internally, and wires everything (schema stitching + stack exports). */
  let makePlatform: (
    ~version: string,
    ~plugins: array<module(PluginMaker)>,
  ) => unit

  /** Deploy only the platform (admin components, scheduler, shared API).
      No plugins are deployed — each plugin deploys independently via `deployPlugin`. */
  let deployPlatform: (~version: string) => unit

  /** Deploy a single plugin as an independent stack.
      Creates its own scheduler and exports stack outputs for cross-stack consumption. */
  let deployPlugin: (~version: string, ~plugin: module(PluginMaker)) => pluginOutputs
}
