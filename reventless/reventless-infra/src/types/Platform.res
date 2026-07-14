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

// Type alias so `deployPlugin` can reference `Plugin.outputs` inside module type T,
// where `module Plugin: Plugin.T` shadows the package-level Plugin module.
type pluginOutputs = Plugin.outputs

// Module type alias so StateViewSliceStream can reference the component T
// without being confused by the `module StateViewSlice` declaration inside T.
module type StateViewSliceComponentT = StateViewSlice.T

// Same trick for ReadModelStream: the nested `module ReadModel` declaration
// inside T shadows the package-level ReadModel for later declarations, so
// reference its component T through this file-scope alias.
module type ReadModelComponentT = ReadModel.T

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
    /** Async variant — uses FIFO channel, returns `CommandPending`. */
    module MakeAsync: (
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

  /** Factory for stream-enabled read model components — identical to `ReadModel`
      but the QueryDb table has a DynamoDB Stream so the platform wires a
      `StateTopic` Lambda that pushes row changes to the AppSync Events API
      (Source B subscriptions / AutoUI live updates). In-memory: same as
      `ReadModel` (no streams). */
  module ReadModelStream: {
    module Make: (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ) => ReadModelComponentT with module Spec = Spec and type api = api and type role = role
  }

  /** Factory for extension point components (single mapping). */
  module ExtensionPoint: {
    module Make: (
      Mapping: ExtensionPointMapping.Mapping,
    ) => ExtensionPoint.T

    /** Two-mapping variant — merges per-slice EP mappings. */
    module Make2: (
      Mapping1: ExtensionPointMapping.Mapping,
      Mapping2: ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
    ) => ExtensionPoint.T

    /** Three-mapping variant — merges per-slice EP mappings. */
    module Make3: (
      Mapping1: ExtensionPointMapping.Mapping,
      Mapping2: ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
      Mapping3: ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
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
    module Make: (
      Spec: Reventless.StateChangeSlice.Spec,
      Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
    ) => StateChangeSlice.T with module Spec = Spec
    /** Async variant — uses FIFO channel, returns `CommandPending`. */
    module MakeAsync: (
      Spec: Reventless.StateChangeSlice.Spec,
      Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
    ) => StateChangeSlice.T with module Spec = Spec
  }

  /** Factory for DCB read-side state-view slice components. */
  module StateViewSlice: {
    module Make: (
      Spec: Reventless.StateViewSlice.Spec,
      Projection: Reventless.StateViewSlice.Projection with module Spec := Spec,
    ) => StateViewSlice.T with module Spec = Spec
  }

  /** Factory for stream-enabled state-view slice components (enables Source B subscriptions). */
  module StateViewSliceStream: {
    module Make: (
      Spec: Reventless.StateViewSlice.Spec,
      Projection: Reventless.StateViewSlice.Projection with module Spec := Spec,
    ) => StateViewSliceComponentT with module Spec = Spec
  }

  /** Factory for DCB automation slice components (TODO list pattern). */
  module AutomationSlice: {
    module Make: (
      Spec: Reventless.AutomationSlice.Spec,
      Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
    ) => AutomationSlice.T with module Spec = Spec
  }

  /** Factory for DCB outbound translation slice components (tracked external calls). */
  module OutboundTranslationSlice: {
    module Make: (
      Spec: Reventless.OutboundTranslationSlice.Spec,
      Translation: Reventless.OutboundTranslationSlice.Translation with module Spec := Spec,
    ) => OutboundTranslationSlice.T with module Spec = Spec
  }

  /** Factory for DCB inbound translation slice components (external input to commands). */
  module InboundTranslationSlice: {
    module Make: (
      Spec: Reventless.InboundTranslationSlice.Spec,
      Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
    ) => InboundTranslationSlice.T with module Spec = Spec
  }

  /** Whether this platform supports MCP (Model Context Protocol) for AI agent access.
      In-memory: starts an MCP server alongside GraphQL in makePlatform.
      AWS: deploys a Lambda Function URL with Streamable HTTP transport. */
  type mcpSupported = | @as(true) McpSupported | @as(false) McpNotSupported
  let mcpSupported: mcpSupported

  /** Which AppSync API a plugin's resolvers and schema are deployed to.
      Domain — the application-facing API (default, backwards-compatible).
      Platform — the admin/Platform_Sync* API (for framework-internal plugins). */
  type apiTarget = Domain | Platform

  /** Factory for plugin deployment units. */
  module Plugin: Plugin.T with type api = api and type role = role

  /** Module type for plugin assembly — matches the `make` function produced by
      every plugin's `Make` functor. Pass first-class modules to `makePlatform`. */
  module type PluginMaker = {
    let make: unit => Plugin.component
  }

  /** Optional host UI shell bundle. When set, the platform hosts the static
      shell (e.g. reventless-ui's host-shell `dist/`) on its own CDN and writes
      a `config.json` next to `index.html` so the shell discovers the API
      endpoint at boot. In-memory platforms typically ignore this — the shell
      is served by `vite dev` against the running in-process GraphQL server. */
  type hostUiBundleConfig = {
    assetsDir: string,
    bundleVersion: string,
  }

  /** Deploy a complete platform: creates the scheduler, builds each plugin,
      creates admin components internally, and wires everything (schema stitching + stack exports). */
  let makePlatform: (
    ~version: string,
    ~plugins: array<module(PluginMaker)>,
  ) => unit

  /** Deploy only the platform (admin components, scheduler, shared API).
      No plugins are deployed — each plugin deploys independently via `deployPlugin`.
      Pass `~hostUiBundle` to also host a static host-shell SPA from this stack.
      Returns the Pulumi stack outputs dict for use as the ESM `default` export. */
  let deployPlatform: (
    ~version: string,
    ~hostUiBundle: hostUiBundleConfig=?,
  ) => dict<Pulumi.Output.t<JSON.t>>

  /** Deploy a single plugin as an independent stack.
      Creates its own scheduler and exports stack outputs for cross-stack consumption.
      Pass `~apiTarget=Platform` to route the plugin's resolvers and schema to the Platform API.
      Defaults to `Domain`.
      Returns the Pulumi stack outputs dict for use as the ESM `default` export. */
  let deployPlugin: (~plugin: module(PluginMaker), ~apiTarget: apiTarget=?) => dict<Pulumi.Output.t<JSON.t>>

  /** Start all servers after all makePlatform/deployPlugin calls are complete.
      In split in-memory mode, servers are deferred until this is called so all
      plugins (domain and platform) can register their schema before serving requests.
      In AWS and unified in-memory mode this is a no-op — server lifecycle is managed
      by Pulumi / existing inline start() calls. */
  let startServers: unit => unit
}
