// Platform — concrete AWS implementation of ReventlessInfra.Platform.T.
//
// Creates a platform instance with pre-wired AWS builders (DynamoDB, Lambda, SQS, SNS).
// Config is applied once at platform creation; component Make functors then take only
// the application-defined arguments (Spec, Behavior, Mappings).
//
// Example:
//   module Platform = Platform.Make()
//   module App = MyPlugin.Make(Platform)
//
// Custom config:
//   module Platform = Platform.MakeWithConfig({let splitApi = false; let cloner = true})

let log = ReventlessCore.Logger.fromEnv()

// Deploy-time schema-push shrink-guard threshold (deploy-time analogue of the
// runtime RUNTIME_SCHEMA_SHRINK_THRESHOLD in AdminEventCollectorEntryPoint.mjs).
// A push whose stitched SDL has fewer than (threshold × live) root fields is
// refused as a likely stale concurrent-deploy stitch. Default 0.5; override via
// DEPLOY_SCHEMA_SHRINK_THRESHOLD; values outside (0, 1) fall back to the default.
@val @scope("process") external processEnv: Dict.t<string> = "env"
let deploySchemaShrinkThreshold: float =
  switch processEnv->Dict.get("DEPLOY_SCHEMA_SHRINK_THRESHOLD")->Option.flatMap(Float.fromString) {
  | Some(n) if n > 0. && n < 1. => n
  | _ => 0.5
  }

// API config ref — populated during MakeWithConfig so slice builders
// can access api/apiRole outside the functor constraint.
//
// domainApi/domainApiRole: the API that plugin stacks publish mutations to.
// platformApi/platformApiRole: the API that hosts admin and Platform_Sync* resolvers.
// In unified (non-split) mode both pairs point to the same AppSync resource.
// In split mode they are separate resources created by deployPlatform/makePlatform.
type apiConfig = {
  domainApi: Types.AppSync.api,
  domainApiRole: Types.AppSync.role,
  platformApi: Types.AppSync.api,
  platformApiRole: Types.AppSync.role,
}
let apiConfigRef: ref<option<apiConfig>> = ref(None)
let getApiConfig = () =>
  apiConfigRef.contents->Option.getOrThrow(
    ~message="Platform.getApiConfig() called before MakeWithConfig",
  )

// Split API outputs — populated by makePlatform when splitApi=true.
// Access via getSplitApiOutputs() after makePlatform has been called.
type splitApiOutputs = {
  platformApi: Types.AppSync.api,
  platformApiRole: Types.AppSync.role,
}
let splitApiOutputsRef: ref<option<splitApiOutputs>> = ref(None)

/** Returns the Platform API outputs created in split mode.
    Call after `makePlatform` — returns `None` in unified mode. */
let getSplitApiOutputs = () => splitApiOutputsRef.contents

module MakeWithConfig = (
  Config: {
    let splitApi: bool
    let cloner: bool
    let commandHandlerConfig: ReventlessCore.Runtime.commandHandlerConfigs
    /** B2.3c platform toggle. When `Some`, every DCB EventLog is Postgres-backed
        (no DynamoDB table/stream; a scheduled `PgChangeFeedRelay` drives propagation),
        while aggregate EventLogs stay on DynamoDB. Provisioned by the app via
        `PgConnection.make`. `None` = all-DynamoDB (unchanged). */
    let pgConnection: option<PgConnection.t>
  },
): (
  ReventlessInfra.Platform.T with type api = Types.AppSync.api and type role = Types.AppSync.role
) => {
  // Dispatch per-flavor commandHandlerConfig records to the four runtime
  // builders. Every sub-record is optional; only branches the caller actually
  // supplied propagate, and within each sub-record every field is optional too
  // — `setConfig` just installs the override, defaults remain in the builder.
  Config.commandHandlerConfig.aggregates->Option.forEach(({?sync, ?async}) => {
    sync->Option.forEach(AggregateRuntime_Builder_Single.setConfig)
    async->Option.forEach(AggregateRuntime_Builder_Single_Async.setConfig)
  })
  Config.commandHandlerConfig.stateChanges->Option.forEach(({?sync, ?async}) =>
    PluginRuntime_Builder.setStateChangesConfig(~sync?, ~async?, ())
  )
  // B2.3c: when a PgConnection is supplied, route ALL DCB EventLogs (DcbBackend)
  // AND all classic aggregate EventLogs (EventLogBackend, Single strategies) to
  // Postgres, and record the selections for the change-feed relay wiring in
  // makePlatform below. Set BEFORE the Admin/plugin functors run so the storage
  // Selectables see it.
  Config.pgConnection->Option.forEach((pg: PgConnection.t) => {
    DcbBackend.set({
      connectionConfig: pg.connectionConfig,
      securityGroupId: pg.securityGroupId,
      subnetIds: pg.subnetIds,
      lockStrategy: pg.lockStrategy,
    })
    EventLogBackend.set({
      connectionConfig: pg.connectionConfig,
      securityGroupId: pg.securityGroupId,
      subnetIds: pg.subnetIds,
    })
    // B3.1: app read models / state view slices store to Postgres too. Admin
    // read models are exempt — deploy-time consumers (schema-clobber guard's
    // Plugin-RM scan, PLUGIN_RM_TABLE_NAME gates, retire hooks) query them
    // during `pulumi up` from outside the VPC, and the platform lifecycle
    // depends on them.
    QueryDbBackend.set({
      connectionConfig: pg.connectionConfig,
      securityGroupId: pg.securityGroupId,
      subnetIds: pg.subnetIds,
    })
    QueryDbBackend.exempt(ReventlessCore.PluginsReadModelSpec.name)
    QueryDbBackend.exempt(ReventlessCore.UIFragmentRegistryReadModelSpec.name)
  })
  type api = Types.AppSync.api
  type role = Types.AppSync.role
  type apiTarget = Domain | Platform

  // Ref tracking which API target deployPlugin is currently building for.
  // Domain (default): resolvers/schema go to the application AppSync API.
  // Platform: resolvers/schema go to the admin/Platform_Sync* Core API.
  let currentDeployTarget: ref<apiTarget> = ref(Domain)

  // Determine API source based on platform:stack config.
  // - Platform/monolithic mode (no config): create a real AppSync API resource.
  // - Plugin mode (config set): reference the platform's shared API via StackReference.
  let platformStackRef =
    Pulumi.Config.make(Some("platform"))
    ->Pulumi.Config.get("stack")
    ->Option.map(stack => Pulumi.StackReference.make(stack))

  // Helper: build a phantom GraphQLApi.t from resolved id + endpoint strings.
  let makePhantomApi = (apiId, apiEndpoint): PulumiAws.AppSync.GraphQLApi.t => ({
    id: Pulumi.Output.make(apiId),
    arn: Pulumi.Output.make(""),
    name: Pulumi.Output.make(""),
    uris: Pulumi.Output.make(({graphQL: apiEndpoint, realtime: ""}: PulumiAws.AppSync.GraphQLApi.uris)),
  }: PulumiAws.AppSync.GraphQLApi.t)

  // Helper: build a phantom IAM.Role.t from a resolved role ARN.
  let makePhantomRole = (apiRoleArn): PulumiAws.IAM.Role.t => {
    let roleName =
      apiRoleArn->String.split("/")->Array.at(-1)->Option.getOr(apiRoleArn)
    ({
      arn: Pulumi.Output.make(apiRoleArn),
      id: Pulumi.Output.make(roleName),
      name: Pulumi.Output.make(roleName),
    }: PulumiAws.IAM.Role.t)
  }

  let (domainApi, domainApiRole, platformApi, platformApiRole) = switch platformStackRef {
  | None =>
    let (api, role) = AppSync_Adapter.makeApiResource(~name="DomainApi", ~opts={})
    // In platform/monolithic mode the platform API is not yet known — it is created
    // during deployPlatform/makePlatform and the ref is updated there.
    (api, role, api, role)
  | Some(stackRef) =>
    // Plugin mode — reconstruct phantom API/role from the platform's exported IDs.
    // Consumers only access api.id and role.arn, so other fields are unused.
    //
    // In ESM mode, Pulumi exports are inside the "default" output.
    // Try top-level field first (CJS), fall back to "default".<field> (ESM).
    let defaultOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput("default")

    // ── Domain API (application mutations) ──────────────────────────────────
    let domainApiIdOutput: Pulumi.Output.t<option<string>> =
      stackRef->Pulumi.StackReference.getOutput("domainApiId")
    let domainApiEndpointOutput: Pulumi.Output.t<option<string>> =
      stackRef->Pulumi.StackReference.getOutput("domainApiEndpoint")
    let domainApiRoleArnOutput: Pulumi.Output.t<option<string>> =
      stackRef->Pulumi.StackReference.getOutput("domainApiRoleArn")

    let phantomApi: Types.AppSync.api =
      (domainApiIdOutput, domainApiEndpointOutput, defaultOutput)
      ->Pulumi.Output.all3
      ->Pulumi.Output.apply(((directId, directEndpoint, default)) => {
        let apiId = switch directId {
        | Some(id) => id
        | None =>
          default
          ->Option.flatMap(d => d->JSON.Decode.object)
          ->Option.flatMap(d => d->Dict.get("domainApiId"))
          ->Option.flatMap(v => v->JSON.Decode.string)
          ->Option.getOrThrow
        }
        let apiEndpoint = switch directEndpoint {
        | Some(ep) => ep
        | None =>
          default
          ->Option.flatMap(d => d->JSON.Decode.object)
          ->Option.flatMap(d => d->Dict.get("domainApiEndpoint"))
          ->Option.flatMap(v => v->JSON.Decode.string)
          ->Option.getOrThrow(
            ~message="Platform stack does not export 'domainApiEndpoint' — redeploy the platform stack first",
          )
        }
        makePhantomApi(apiId, apiEndpoint)
      })
    let phantomRole: Types.AppSync.role =
      (domainApiRoleArnOutput, defaultOutput)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((direct, default)) => {
        let domainApiRoleArn = switch direct {
        | Some(arn) => arn
        | None =>
          default
          ->Option.flatMap(d => d->JSON.Decode.object)
          ->Option.flatMap(d => d->Dict.get("domainApiRoleArn"))
          ->Option.flatMap(v => v->JSON.Decode.string)
          ->Option.getOrThrow
        }
        makePhantomRole(domainApiRoleArn)
      })

    // ── Platform API (admin / Platform_Sync* resolvers) ─────────────────────
    let platformApiIdOutput: Pulumi.Output.t<option<string>> =
      stackRef->Pulumi.StackReference.getOutput("platformApiId")
    let platformApiEndpointOutput: Pulumi.Output.t<option<string>> =
      stackRef->Pulumi.StackReference.getOutput("platformApiEndpoint")
    let platformApiRoleArnOutput: Pulumi.Output.t<option<string>> =
      stackRef->Pulumi.StackReference.getOutput("platformApiRoleArn")

    let phantomPlatformApi: Types.AppSync.api =
      (platformApiIdOutput, platformApiEndpointOutput, defaultOutput)
      ->Pulumi.Output.all3
      ->Pulumi.Output.apply(((directPlatId, directPlatEndpoint, default)) => {
        let getFromDefault = key =>
          default
          ->Option.flatMap(d => d->JSON.Decode.object)
          ->Option.flatMap(d => d->Dict.get(key))
          ->Option.flatMap(v => v->JSON.Decode.string)
        let platformApiId =
          directPlatId
          ->Option.orElse(getFromDefault("platformApiId"))
          ->Option.getOrThrow
        let platformApiEndpoint =
          directPlatEndpoint
          ->Option.orElse(getFromDefault("platformApiEndpoint"))
          ->Option.getOrThrow
        makePhantomApi(platformApiId, platformApiEndpoint)
      })
    let phantomPlatformRole: Types.AppSync.role =
      (platformApiRoleArnOutput, defaultOutput)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((directPlat, default)) => {
        let getFromDefault = key =>
          default
          ->Option.flatMap(d => d->JSON.Decode.object)
          ->Option.flatMap(d => d->Dict.get(key))
          ->Option.flatMap(v => v->JSON.Decode.string)
        let platformApiRoleArn =
          directPlat
          ->Option.orElse(getFromDefault("platformApiRoleArn"))
          ->Option.getOrThrow
        makePhantomRole(platformApiRoleArn)
      })

    (phantomApi, phantomRole, phantomPlatformApi, phantomPlatformRole)
  }

  // Expose api/apiRole as Platform.T value bindings so DCB slice builders
  // can access them through the platform interface.
  let api = domainApi
  let apiRole = domainApiRole

  // Populate apiConfig with both domain and platform API references.
  // In platform/monolithic mode, platformApi starts as domainApi and is updated
  // by deployPlatform/makePlatform once the core API resource is created (split mode).
  let () = apiConfigRef := Some({
    domainApi: domainApi,
    domainApiRole: domainApiRole,
    platformApi: platformApi,
    platformApiRole: platformApiRole,
  })

  // AppSync Events API — companion to the GraphQL API for Sources A and B subscriptions.
  // In platform/monolithic mode: created here as a real resource.
  // In plugin mode: reconstructed as a phantom from platform stack exports (eventsApiArn, eventsApiDns).
  let domainEventsApiOpt: option<AppSync_EventsApi.t> =
    switch platformStackRef {
    | None =>
      // Browser host-shell subscribes over WebSocket with a Cognito IdToken,
      // so the Events API must carry a Cognito auth provider. The pool is the
      // same process-cached one the GraphQL API + config.json use.
      let cognitoPool = Platform_Stack.resolveCognitoUserPool()
      let awsRegion =
        Pulumi.Config.make(Some("aws"))->Pulumi.Config.get("region")->Option.getOr("unknown")
      Some(
        AppSync_EventsApi.make(
          ~name="DomainEventsApi",
          ~cognitoUserPoolId=cognitoPool.poolId->Pulumi.Output.asInput,
          ~awsRegion,
          ~opts={},
        ),
      )
    | Some(stackRef) =>
      let eventsApiArnOutput: Pulumi.Output.t<option<string>> =
        stackRef->Pulumi.StackReference.getOutput("eventsApiArn")
      let eventsApiDnsOutput: Pulumi.Output.t<option<string>> =
        stackRef->Pulumi.StackReference.getOutput("eventsApiDns")
      let defaultEventsOutput: Pulumi.Output.t<option<JSON.t>> =
        stackRef->Pulumi.StackReference.getOutput("default")
      let getFromDefault = (default, key) =>
        default
        ->Option.flatMap(d => d->JSON.Decode.object)
        ->Option.flatMap(d => d->Dict.get(key))
        ->Option.flatMap(v => v->JSON.Decode.string)
      let apiArn =
        (eventsApiArnOutput, defaultEventsOutput)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((direct, default)) =>
          direct->Option.orElse(getFromDefault(default, "eventsApiArn"))
        )
      let dns =
        (eventsApiDnsOutput, defaultEventsOutput)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((direct, default)) =>
          direct->Option.orElse(getFromDefault(default, "eventsApiDns"))
        )
      let api: PulumiAws.AwsNative.AppSync.Api.t = {
        apiId: Pulumi.Output.make(""),
        apiArn: apiArn->Pulumi.Output.apply(v => v->Option.getOr("")),
        dns: dns->Pulumi.Output.apply(dnsHttp => ({
          PulumiAws.AwsNative.AppSync.Api.http: ?dnsHttp,
        }: PulumiAws.AwsNative.AppSync.Api.dns)),
        name: Pulumi.Output.make(""),
      }
      let eventsApi: AppSync_EventsApi.t = {
        name: "DomainEventsApi",
        api,
        defaultNamespace: None,
      }
      Some(eventsApi)
    }

  // B3.3: publish the events-API endpoint + ARN to the projection-Lambda runtime
  // builders, so a subscription-enabled Postgres read model / view slice gets the
  // APPSYNC_ENDPOINT env + appsync:EventPublish IAM at their `finish`. Set once
  // here (before plugins build) in both monolithic and plugin-stack mode — the
  // phantom events API carries apiArn + dns, so httpEndpoint resolves either way.
  switch domainEventsApiOpt {
  | Some(eventsApi) =>
    let cfg = {
      EventCollectorRuntime_Builder_Single.endpoint: AppSync_EventsApi.httpEndpoint(eventsApi),
      apiArn: eventsApi.api.apiArn,
    }
    EventCollectorRuntime_Builder_Single.setEventsApiConfig(cfg)
    StateViewSliceRuntime_Builder_Single.setEventsApiConfig({
      StateViewSliceRuntime_Builder_Single.endpoint: AppSync_EventsApi.httpEndpoint(eventsApi),
      apiArn: eventsApi.api.apiArn,
    })
  | None => ()
  }

  // Returns the AppSync API/role to attach resolvers to for the current deploy target.
  // Hoisted above ApiConfig so the module can reference them as thunks.
  let resolveTargetApi = () =>
    switch currentDeployTarget.contents {
    | Domain => domainApi
    | Platform =>
      switch apiConfigRef.contents {
      | Some({platformApi}) => platformApi
      | None => domainApi // fallback: platform API not yet constructed
      }
    }

  let resolveTargetApiRole = () =>
    switch currentDeployTarget.contents {
    | Domain => domainApiRole
    | Platform =>
      switch apiConfigRef.contents {
      | Some({platformApiRole}) => platformApiRole
      | None => domainApiRole
      }
    }

  // Thunk-based ApiConfig — evaluated at make() time, reads currentDeployTarget set by deployPlugin.
  module ApiConfig = {
    let api = resolveTargetApi
    let apiRole = resolveTargetApiRole
  }

  module Aggregate = {
    // Default deployment strategy is Single (one Lambda per plugin shared by all
    // aggregates). To override per-plugin or per-aggregate, swap the builder at
    // the call site (e.g., ReventlessAws.Aggregate_Builder_PerAggregate.Make,
    // _Micro, _NoResolver) — see docs/plans/Backlog/aws-deployment-strategy.md.
    module Make = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
    ): (
      ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
    ) =>
      Aggregate_Builder_Single.Make(Spec, Behavior, EventMappings)
    /** Async variant — uses FIFO SQS channel, commands return `CommandPending`. */
    module MakeAsync = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
    ): (
      ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
    ) =>
      Aggregate_Builder_Single_Async.Make(Spec, Behavior, EventMappings)
  }

  module ReadModel = {
    module Make = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ): (
      ReventlessInfra.ReadModel.T
        with module Spec = Spec
        and type api = Types.AppSync.api
        and type role = Types.AppSync.role
    ) =>
      ReadModel_Builder_Single.Make(Spec, Mappings)
  }

  /** Stream-enabled read model — DynamoDB Stream + StateTopic Lambda for
      AppSync Events (Source B) live updates. */
  module ReadModelStream = {
    module Make = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ): (
      ReventlessInfra.ReadModel.T
        with module Spec = Spec
        and type api = Types.AppSync.api
        and type role = Types.AppSync.role
    ) =>
      ReadModel_Builder_Single_Stream.Make(Spec, Mappings)
  }

  module ExtensionPoint = {
    module Make = (
      Mapping: ReventlessInfra.ExtensionPointMapping.Mapping,
    ): ReventlessInfra.ExtensionPoint.T => {
      module Spec = Mapping.ExtensionPoint
      module CompiledMapping = ReventlessInfra.ExtensionPointMapping.Make(Mapping)
      module Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec = {
        module type Mapping = ReventlessInfra.ExtensionPointMapping.T
          with module ExtensionPoint := Spec
        let name = Mapping.Delegate.name
        // The mapping FILE's moduleUrl, not the spec's — the EventCollector
        // runtime dynamic-imports this URL to find mapOutgoingEvent. Read
        // through %raw because moduleUrl isn't part of the Mapping signature
        // (would force every test/internal mapping to declare it); user
        // mapping files reliably expose it via the @@reventless.spec PPX.
        // Spec.moduleUrl is the fallback when the JS-level property is absent.
        let moduleUrl = Mapping.moduleUrl
        let mappings: array<module(Mapping)> = [module(CompiledMapping)]
      }
      module Inner = ExtensionPoint_Builder.Make(Spec, Mappings)
      include Inner
    }

    module Make2 = (
      Mapping1: ReventlessInfra.ExtensionPointMapping.Mapping,
      Mapping2: ReventlessInfra.ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
    ): ReventlessInfra.ExtensionPoint.T => {
      module Spec = Mapping1.ExtensionPoint
      module CM1 = ReventlessInfra.ExtensionPointMapping.Make(Mapping1)
      module CM2 = ReventlessInfra.ExtensionPointMapping.Make(Mapping2)
      module Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec = {
        module type Mapping = ReventlessInfra.ExtensionPointMapping.T
          with module ExtensionPoint := Spec
        let name =
          Mapping1.Delegate.name ++ "+" ++ Mapping2.Delegate.name
        // First mapping's URL — matches the user-extension merge convention.
        // See Make's moduleUrl comment for the %raw rationale.
        let moduleUrl = Mapping1.moduleUrl
        let mappings: array<module(Mapping)> = [module(CM1), module(CM2)]
      }
      module Inner = ExtensionPoint_Builder.Make(Spec, Mappings)
      include Inner
    }

    module Make3 = (
      Mapping1: ReventlessInfra.ExtensionPointMapping.Mapping,
      Mapping2: ReventlessInfra.ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
      Mapping3: ReventlessInfra.ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
    ): ReventlessInfra.ExtensionPoint.T => {
      module Spec = Mapping1.ExtensionPoint
      module CM1 = ReventlessInfra.ExtensionPointMapping.Make(Mapping1)
      module CM2 = ReventlessInfra.ExtensionPointMapping.Make(Mapping2)
      module CM3 = ReventlessInfra.ExtensionPointMapping.Make(Mapping3)
      module Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec = {
        module type Mapping = ReventlessInfra.ExtensionPointMapping.T
          with module ExtensionPoint := Spec
        let name =
          Mapping1.Delegate.name ++
          "+" ++
          Mapping2.Delegate.name ++
          "+" ++
          Mapping3.Delegate.name
        // First mapping's URL — matches the user-extension merge convention.
        // See Make's moduleUrl comment for the %raw rationale.
        let moduleUrl = Mapping1.moduleUrl
        let mappings: array<module(Mapping)> = [module(CM1), module(CM2), module(CM3)]
      }
      module Inner = ExtensionPoint_Builder.Make(Spec, Mappings)
      include Inner
    }

    module MakeMulti = (
      Spec: ReventlessInfra.ExtensionPointMapping.Spec,
      Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
    ): ReventlessInfra.ExtensionPoint.T => ExtensionPoint_Builder.Make(Spec, Mappings)
  }

  module Extension = {
    module Make = (
      Mapping: ReventlessInfra.ExtensionMapping.Mapping,
    ): ReventlessInfra.Extension.Blueprint => {
      module Spec = Mapping.ExtensionPoint
      module CompiledMapping = ReventlessInfra.ExtensionMapping.Make(Mapping)
      module type Mapping = ReventlessInfra.ExtensionMapping.T
        with module ExtensionPoint := Spec
      let name = Mapping.Delegate.name
      let moduleUrl = Mapping.moduleUrl
      let delegateModuleUrl = Mapping.delegateModuleUrl
      let mappings: array<module(Mapping)> = [module(CompiledMapping)]
    }

  }

  module Task = {
    module Make = (Spec: ReventlessInfra.Task.Spec): (
      ReventlessInfra.Task.T with module Spec = Spec
    ) => Task_Builder_PerBucket.Make(Spec)
  }

  module Counter = Counter_Builder.Make(ApiConfig)

  module StateChangeSlice = {
    module Make = (
      Spec: Reventless.StateChangeSlice.Spec,
      Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
    ): (ReventlessInfra.StateChangeSlice.T with module Spec = Spec) =>
      StateChangeSlice_Builder.Make(Spec, Behavior)
    /** Async variant — uses FIFO SQS channel, commands return `CommandPending`. */
    module MakeAsync = (
      Spec: Reventless.StateChangeSlice.Spec,
      Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
    ): (ReventlessInfra.StateChangeSlice.T with module Spec = Spec) => {
      include StateChangeSlice_Builder.Make(Spec, Behavior)
      let isAsync = true
    }
  }

  module StateViewSlice = {
    include StateViewSlice_Builder.Make(ApiConfig)
  }
  module StateViewSliceStream = {
    @@warning("-60")
    include StateViewSlice_Builder_Stream.Make(ApiConfig)
  }
  module AutomationSlice = {
    include AutomationSlice_Builder.Make(ApiConfig)
  }
  module OutboundTranslationSlice = {
    include OutboundTranslationSlice_Builder.Make(ApiConfig)
  }
  module InboundTranslationSlice = InboundTranslationSlice_Builder.Make(ApiConfig)

  // Empty base fragment — no types, no mutations, no queries.
  // Used by the plugin Api in split mode so plugin schema has no core fields.
  let emptyBaseFragment = ReventlessCore.GraphQL_Stitcher.encode({
    types: [],
    mutations: [],
    queries: [],
    subscriptions: [],
  })

  module Api = {
    module Make = (
      FragmentConfig: {
        let baseFragment: ReventlessInfra.Api.schemaFragment
      },
    ): ReventlessInfra.Api.T => {
      module Builder = ReventlessCore.Api_Builder.Make(AppSync_Adapter)
      // In split mode, the plugin API uses an empty base fragment so plugin schema
      // has no core fields. In unified mode, use the provided base fragment as-is.
      let effectiveBaseFragment = if Config.splitApi {
        emptyBaseFragment
      } else {
        FragmentConfig.baseFragment
      }
      let make = (~name, ~opts=?) =>
        Builder.make(~name, ~baseFragment=effectiveBaseFragment, ~opts?)
    }
  }

  // ── Typed identity casts — see Platform_Casts.res for rationale ─────────
  open Platform_Casts

  // AWS platform hooks — all AWS-specific callbacks defined as a record.
  // In-memory hooks (mutationResolverHook etc.) are absent (optional = None).
  let deploySchemaPrefix = "deploy-schema:"
  let deploySchemaPlatformPrefix = "deploy-schema-platform:"
  let deploySchemaHashPrefix = "deploy-schema-hash:"

  let readSchemaHash = async (~tableName: string, ~apiId: string): option<string> => {
    open AwsSdk.DynamoDb.DocumentClient
    let key = Dict.fromArray([("id", `${deploySchemaHashPrefix}${apiId}`->JSON.Encode.string)])
    try {
      let result = await GetCommand.send(GetCommand.make({GetCommand.tableName, key}))
      result.item
      ->Option.flatMap(item => item->JSON.Decode.object)
      ->Option.flatMap(d => d->Dict.get("hash"))
      ->Option.flatMap(v => v->JSON.Decode.string)
    } catch {
    | _ => None
    }
  }

  let writeSchemaHash = async (~tableName: string, ~apiId: string, ~hash: string): unit => {
    open AwsSdk.DynamoDb.DocumentClient
    let item =
      Dict.fromArray([
        ("id", `${deploySchemaHashPrefix}${apiId}`->JSON.Encode.string),
        ("hash", hash->JSON.Encode.string),
      ])->JSON.Encode.object
    let _ = await PutCommand.send(PutCommand.make({PutCommand.tableName, item}))
  }

  // (Deploy-time retire hook removed: supersession is now decided by the
  // name-keyed Plugin aggregate (VersionSuperseded) — no RM scan drives a command.)

  // Define api/apiRole refs before the hooks record so the hook closures can capture
  // them directly. This is necessary because the dcbAppSyncResolverHook and
  // inboundAppSyncResolverHook fire inside a deferred Pulumi.Output.apply callback
  // (in Plugin_Builder.builderOutputs), AFTER deployPlugin has returned and reset
  // currentDeployTarget to Domain. Reading hooks.apiRef directly gives the correct
  // targetApi that was set before plugin.make() and is never reset.
  let hooksApiRef: ref<option<ReventlessCore.Plugin_Helpers.hookedValue<unknown>>> = ref(None)
  let hooksApiRoleRef: ref<option<ReventlessCore.Plugin_Helpers.hookedValue<unknown>>> = ref(None)

  let resolveHookedApi = (): Types.AppSync.api =>
    switch hooksApiRef.contents {
    | Some({val}) => Obj.magic(val)
    | None => resolveTargetApi()
    }

  let hooks: ReventlessCore.Plugin_Helpers.platformHooks = {
    // AWS uses Interstack for admin extension points — leave ref at empty dict.
    adminExtensionPoints: ref(Pulumi.Output.make(Dict.make())),
    // Platform context — populated by makePlatform/deployPlugin before plugin build.
    scheduler: ref(None),
    schedulerRoleUrn: ref(Pulumi.Output.make("")),
    api: hooksApiRef,
    apiRole: hooksApiRoleRef,
    deployTarget: ref("Domain"),
    inboundAppSyncResolverHook: ({runtime, fieldNames, externalInputSchemas: _, opts}) => {
      let runtimeTyped: ReventlessCore.Runtime.environment<Util.Lambda.runtimeParts> =
        runtime->asLambdaRuntime
      InboundTranslationResolvers_AppSync.make(
        ~api=resolveHookedApi(),
        ~runtime=runtimeTyped,
        ~fieldNames,
        ~opts,
      )
    },
    dcbAppSyncResolverHook: ({runtime, fieldNames, tags, opts}) => {
      let runtimeTyped: ReventlessCore.Runtime.environment<Util.Lambda.runtimeParts> =
        runtime->asLambdaRuntime
      CommandGeneratorResolvers_AppSync.makeDcb(
        ~api=resolveHookedApi(),
        ~runtime=runtimeTyped,
        ~fieldNames,
        ~tags,
        ~opts,
      )
    },

    // Admin-side schema push, gated on admin DataSources via adminBarrier.
    // Platform_Admin.construct invokes this and chains createResolvers behind
    // the returned Output — so admin CreateResolver calls fire only after
    // StartSchemaCreation completes and the AppSync API-level lock is
    // released. This replaces the prior outer schema pushes that lived in
    // makePlatform / deployPlatform and raced admin createResolvers.
    //
    // Target API selection (read late so splitApiOutputsRef, populated by
    // makePlatform / deployPlatform before Admin.construct fires, is visible):
    //   - split mode: platformApi from splitApiOutputsRef
    //   - unified mode / not-yet-populated: domainApi
    preAdminResolversSchemaHook: (~adminBarrier) => {
      let targetApi = switch splitApiOutputsRef.contents {
      | Some({platformApi}) => platformApi
      | None => domainApi
      }
      let adminBaseFragment = AppSync_Adapter.injectAwsAuthAll(
        ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
        ~group="Admin",
      )
      let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
        ~baseFragment=adminBaseFragment,
        ~pluginFragments=[],
      )
      (targetApi, adminBarrier)
      ->Pulumi.Output.all2
      ->Pulumi.Output.flatMap(((api, _)) =>
        api.id->Pulumi.Output.flatMap(apiId => {
          log.info(~comp="preAdminResolversSchemaHook", `Pushing admin schema to ${apiId}`)
          let client = AppSync_Adapter.getClient()
          client
          ->AppSync_Adapter.startSchemaCreationRetrying({apiId, definition: sdl})
          ->Promise.then(async _ => {
            log.info(
              ~comp="preAdminResolversSchemaHook",
              "startSchemaCreation called, waiting for ACTIVE",
            )
            await AppSync_Adapter.waitForSchemaActive(client, apiId)
            log.info(~comp="preAdminResolversSchemaHook", "schema is ACTIVE")
          })
          ->Pulumi.Output.fromPromise
        })
      )
    },

    // Accumulate fragments across independent plugin deployments: each plugin
    // writes its fragment to the Plugin RM table (keyed "deploy-schema:<name>")
    // at deploy time. The hook then scans for ALL deploy-schema entries and
    // stitches them together — ensuring the schema is cumulative rather than
    // overwritten by each plugin deployment.
    preResolversSchemaHook: (~name, ~version, pluginFragment) => {
      log.info(
        ~comp="preResolversSchemaHook",
        `Pushing schema for plugin ${name}@${version} to AppSync`,
      )

      // Capture deploy target synchronously — deployPlugin resets currentDeployTarget to
      // Domain after P.make() returns, before any Pulumi.Output async callbacks run.
      let capturedDeployTarget = currentDeployTarget.contents

      // Select DynamoDB key prefix and target AppSync API based on the current deploy target.
      // Domain plugins use "deploy-schema:" and the Domain API (default behaviour).
      // Platform plugins use a separate "deploy-schema-platform:" namespace and the Core API,
      // so their cumulative schema is kept independent from the Domain API's schema.
      let (schemaPrefix, targetApi) = switch capturedDeployTarget {
      | Domain => (deploySchemaPrefix, domainApi)
      | Platform =>
        let api = switch apiConfigRef.contents {
        | Some({platformApi}) => platformApi
        | None => domainApi // fallback: Core API not yet constructed
        }
        (deploySchemaPlatformPrefix, api)
      }

      // Read a string output from the platform StackReference, falling back to
      // the bundled "default" output object if the named export is not present
      // (matches the layout Pulumi emits when a stack uses a single default
      // export rather than per-key exports).
      let readStackRefString = (stackRef, key) => {
        let direct: Pulumi.Output.t<option<JSON.t>> =
          stackRef->Pulumi.StackReference.getOutput(key)
        let defaultOutput: Pulumi.Output.t<option<JSON.t>> =
          stackRef->Pulumi.StackReference.getOutput("default")
        (direct, defaultOutput)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((direct, default)) =>
          switch direct->Option.flatMap(v => v->JSON.Decode.string) {
          | Some(name) => Some(name)
          | None =>
            default
            ->Option.flatMap(d => d->JSON.Decode.object)
            ->Option.flatMap(d => d->Dict.get(key))
            ->Option.flatMap(v => v->JSON.Decode.string)
          }
        )
      }

      // Prefer the dedicated PluginSchemaPersistence table (post-platform-fix);
      // fall back to the Plugin RM table for backward compatibility with
      // platforms deployed before the schema-persistence table existed. The
      // Plugin RM table must not be reused for new schema-fragment writes —
      // doing so leaks deploy-schema rows through the Platform_Plugins AppSync
      // Connection resolver.
      let schemaPersistenceTableNameOutput: Pulumi.Output.t<option<string>> = switch platformStackRef {
      | Some(stackRef) =>
        (
          readStackRefString(stackRef, "pluginSchemaPersistenceTableName"),
          readStackRefString(stackRef, "pluginRmTableName"),
        )
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((dedicated, legacy)) =>
          switch dedicated {
          | Some(_) as s => s
          | None => legacy
          }
        )
      | None => Pulumi.Output.make(None)
      }

      schemaPersistenceTableNameOutput
      ->Pulumi.Output.flatMap(tableNameOpt => {
        // Write this plugin's fragment to DynamoDB, then scan all deploy-schema
        // entries to collect every deployed plugin's fragment.
        let writeAndScanFragments = () =>
          switch tableNameOpt {
          | None =>
            log.info(
              ~comp="preResolversSchemaHook",
              "No pluginSchemaPersistenceTableName / pluginRmTableName — skipping fragment persistence",
            )
            Promise.resolve([pluginFragment])
          | Some(tableName) =>
            open AwsSdk.DynamoDb.DocumentClient
            // Write this plugin's fragment so subsequent plugin deployments find it.
            let deployItem =
              Dict.fromArray([
                ("id", `${schemaPrefix}${name}`->JSON.Encode.string),
                ("fragment", pluginFragment.encoded->JSON.Encode.string),
              ])->JSON.Encode.object
            log.info(
              ~comp="preResolversSchemaHook",
              `Writing deploy-schema entry for ${name} to ${tableName}`,
            )
            // Paginated scan — accumulate every deploy-schema entry across pages.
            // A single ScanCommand returns at most 1 MB before yielding a
            // LastEvaluatedKey; loop until the table is exhausted so a platform
            // with many plugin fragments never stitches a partial schema.
            let scanAllDeploySchemaItems = async () => {
              let allItems = []
              let startKey = ref(None)
              let more = ref(true)
              while more.contents {
                let result = await ScanCommand.send(
                  ScanCommand.make({
                    ScanCommand.tableName: tableName,
                    filterExpression: "begins_with(#id, :prefix)",
                    expressionAttributeNames: Dict.fromArray([("#id", "id")]),
                    expressionAttributeValues: Dict.fromArray([
                      (":prefix", schemaPrefix->JSON.Encode.string),
                    ]),
                    exclusiveStartKey: ?startKey.contents,
                  }),
                )
                result.items->Option.getOr([])->Array.forEach(item => allItems->Array.push(item))
                switch result.lastEvaluatedKey {
                | Some(_) as k => startKey := k
                | None => more := false
                }
              }
              allItems
            }

            PutCommand.send(PutCommand.make({PutCommand.tableName: tableName, item: deployItem}))
            ->Promise.then(_ => {
              // Scan for all deploy-schema entries from previously deployed plugins.
              log.info(
                ~comp="preResolversSchemaHook",
                `Scanning ${tableName} for deploy-schema entries`,
              )
              scanAllDeploySchemaItems()
            })
            ->Promise.then(items => {
              let fragments = items->Array.filterMap(item => {
                try {
                  let obj = item->JSON.stringify->JSON.parseOrThrow
                  switch obj->JSON.Decode.object->Option.flatMap(d => d->Dict.get("fragment")) {
                  | Some(fragmentJson) =>
                    switch fragmentJson->JSON.Decode.string {
                    | Some(encoded) =>
                      Some({Reventless.Plugin.encoded, protocol: "graphql"})
                    | None => None
                    }
                  | None => None
                  }
                } catch {
                | _ => None
                }
              })
              log.info(
                ~comp="preResolversSchemaHook",
                `Found ${fragments->Array.length->Int.toString} deploy-schema entries`,
              )
              Promise.resolve(fragments)
            })
            ->Promise.catch(err => {
              let msg =
                err
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("unknown")
              log.info(
                ~comp="preResolversSchemaHook",
                `DynamoDB write/scan failed (${msg}) — using current plugin only`,
              )
              Promise.resolve([pluginFragment])
            })
          }

        targetApi->Pulumi.Output.flatMap(api =>
          api.id->Pulumi.Output.flatMap(apiId => {
            // Serialise write-row → scan → stitch → push under the shared
            // schema-push lease so a concurrent peer's stale scan can't clobber
            // this stack's fields (see AppSync_Adapter.withSchemaPushLock).
            let runSchemaPush = () => {
            writeAndScanFragments()
            ->Promise.then(async allPluginFragments => {
              // Base fragment selection:
              // - Platform target: always include admin base (the Core API owns admin ops).
              // - Domain target, split mode: empty base (admin lives on Core API).
              // - Domain target, unified mode: include admin base (single API has everything).
              // Use capturedDeployTarget (set synchronously above) — currentDeployTarget has
              // been reset to Domain by deployPlugin before this async callback runs.
              let baseFragment = switch capturedDeployTarget {
              | Platform =>
                AppSync_Adapter.injectAwsAuthAll(
                  ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
                  ~group="Admin",
                )
              | Domain =>
                if Config.splitApi {
                  emptyBaseFragment
                } else {
                  AppSync_Adapter.injectAwsAuthAll(
                    ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
                    ~group="Admin",
                  )
                }
              }
              let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
                ~baseFragment,
                ~pluginFragments=allPluginFragments,
              )
              let currentHash = AppSync_Adapter.sha256Hex(sdl)
              let storedHash = switch tableNameOpt {
              | Some(tn) => await readSchemaHash(~tableName=tn, ~apiId)
              | None => None
              }
              let client = AppSync_Adapter.getClient()

              // Introspect the live schema once — reused for the hash-match
              // drift/repair check and the catastrophic-shrink guard on the push.
              let liveSdl = await AppSync_Adapter.getIntrospectionSdl(client, apiId)

              // The stored hash records what the DEPLOY last pushed. A runtime
              // re-stitch (mkUpdateApiSchema) can clobber the live schema
              // out-of-band WITHOUT updating this hash, so a matching hash does
              // not guarantee the live schema is intact. Before trusting the
              // hash to skip the push, introspect the live schema and confirm it
              // still carries at least as many root-type (Mutation + Query +
              // Subscription) fields as the SDL we would push. If it has drifted
              // (shrunk) — or cannot be introspected despite a stored hash, which
              // means a real failure rather than a first deploy — force the
              // repair push so a clobbered schema heals on the next deploy.
              let countRoots = s =>
                ReventlessCore.GraphQL_Stitcher.countRootTypeFields(~sdl=s, ~typeName="Mutation") +
                ReventlessCore.GraphQL_Stitcher.countRootTypeFields(~sdl=s, ~typeName="Query") +
                ReventlessCore.GraphQL_Stitcher.countRootTypeFields(
                  ~sdl=s,
                  ~typeName="Subscription",
                )
              let skipPush = switch storedHash {
              | Some(prev) if prev == currentHash =>
                let expected = countRoots(sdl)
                let live = countRoots(liveSdl)
                if liveSdl == "" {
                  log.info(
                    ~comp="preResolversSchemaHook",
                    `hash matches but live schema could not be introspected — forcing repair push (check appsync:GetIntrospectionSchema permission)`,
                  )
                  false
                } else if live < expected {
                  log.info(
                    ~comp="preResolversSchemaHook",
                    `hash matches but live schema drifted (${live->Int.toString} root field(s) live vs ${expected->Int.toString} expected) — forcing repair push`,
                  )
                  false
                } else {
                  log.info(
                    ~comp="preResolversSchemaHook",
                    `SDL unchanged (hash ${currentHash->String.slice(~start=0, ~end=12)}…) and live schema intact (${live->Int.toString} root fields); skipping push`,
                  )
                  true
                }
              | _ => false
              }
              if !skipPush {
                // Shrink guard — deploy-time counterpart of the runtime
                // mkUpdateApiSchema guard (AdminEventCollectorEntryPoint.mjs).
                // Plugin/service stacks share one AppSync API and StartSchemaCreation
                // REPLACES the whole schema. A concurrent peer that scanned the
                // deploy-schema table before this stack wrote its fragment row
                // stitches an SDL missing this stack's fields; pushing it would drop
                // the live fields and orphan their resolvers (NotFoundException: No
                // field named X). Refuse a push that would catastrophically shrink
                // the live schema — the field-owner's own deploy (whose scan includes
                // its freshly-written row) pushes the complete set.
                // isCatastrophicSchemaShrink returns false when the live schema is
                // empty (first deploy / introspection unavailable), so the initial
                // push still proceeds.
                if (
                  ReventlessCore.GraphQL_Stitcher.isCatastrophicSchemaShrink(
                    ~currentSdl=liveSdl,
                    ~newSdl=sdl,
                    ~threshold=deploySchemaShrinkThreshold,
                  )
                ) {
                  log.error(
                    ~comp="preResolversSchemaHook",
                    `ABORTED schema push for ${apiId}: stitched SDL (${countRoots(
                        sdl,
                      )->Int.toString} root field(s)) would catastrophically shrink the live schema (${countRoots(
                        liveSdl,
                      )->Int.toString} root field(s), threshold ${deploySchemaShrinkThreshold->Float.toString}) — refusing to clobber resolvers (likely a stale concurrent-deploy scan)`,
                  )
                } else {
                  log.info(
                    ~comp="preResolversSchemaHook",
                    `Pushing schema to API ${apiId} (${allPluginFragments->Array.length->Int.toString} plugin fragments, new hash: ${currentHash->String.slice(~start=0, ~end=12)}…)`,
                  )
                  await client->AppSync_Adapter.startSchemaCreationRetrying({
                    apiId,
                    definition: sdl,
                  })
                  log.info(
                    ~comp="preResolversSchemaHook",
                    "startSchemaCreation called, waiting for ACTIVE",
                  )
                  await AppSync_Adapter.waitForSchemaActive(client, apiId)
                  log.info(~comp="preResolversSchemaHook", "Schema is ACTIVE")
                  switch tableNameOpt {
                  | Some(tn) =>
                    await writeSchemaHash(~tableName=tn, ~apiId, ~hash=currentHash)
                  | None => ()
                  }
                }
              }

              // No deploy-time retire scan: the name-keyed Plugin aggregate
              // decides supersession itself (VersionSuperseded) when the new
              // version connects, so the manifest carries only the current
              // version without any RM-read-driven command.
            })
            }

            (
              switch tableNameOpt {
              | Some(tableName) =>
                AppSync_Adapter.withSchemaPushLock(~tableName, ~apiId, runSchemaPush)
              | None => runSchemaPush()
              }
            )->Pulumi.Output.fromPromise
          })
        )
      })
    },
    // DCB EventLog created hook — extracts DynamoDB table name for DCB CommandTopic Lambda handler.
    // Postgres-backed DCB logs (B2.3c) create no table, so there is no resource to read:
    // the DCB command Lambda derives its `dcb_event.log_name` from the plugin name and
    // reads the PG connection from DcbBackend, so no table-name registration is needed.
    onDcbEventLogCreated: dcbEventLogUnknown =>
      if !DcbBackend.isPostgres() {
        let dcbEventLog = dcbEventLogUnknown->asDcbEventLogComponent
        let outputs = dcbEventLog->ReventlessCore.Component.outputs
        let tableResource = outputs.resources->Array.getUnsafe(0)
        PluginRuntime_Builder.registerDcbTableName(tableResource.name)
      },
    // DCB CommandTopic created hook — extracts SQS queue URL for slice builders.
    onDcbCommandTopicCreated: dcbCommandTopicUnknown => {
      let commandTopic = dcbCommandTopicUnknown->asDcbCommandTopicComponent
      let channel = commandTopic->ReventlessCore.CommandTopic_Adapter.channel
      let channelParts = channel.parts->asSqsChannelParts
      AutomationSliceRuntime_Builder_Single.setDcbQueueUrl(channelParts.queue.id)
    },
    // DCB slices created hook — finalize slice Lambdas.
    onDcbSlicesCreated: dcbEventLogUnknown => {
      let dcbEventLog = dcbEventLogUnknown->asDcbEventLog
      StateViewSliceRuntime_Builder_Single.finishWithDcbEventLog(dcbEventLog)
      AutomationSliceRuntime_Builder_Single.finish()
    },
    // Heartbeat EP channel hook — extracts SQS queue URL for heartbeat Lambda handler
    // and records the calling plugin's id so the Lambda runtime can emit Connect commands
    // with a non-empty SQS MessageGroupId (FIFO requirement).
    onHeartbeatEpChannelAvailable: (remoteChannelUnknown, ~pluginId) => {
      let remoteChannel = remoteChannelUnknown->asRemoteChannel
      switch remoteChannel.resources->Array.get(0) {
      | Some(resource) =>
        PluginRuntime_Builder.registerHeartbeatConfig(
          ~pluginId,
          ~epQueueUrl=resource.id->Pulumi.Output.make,
          (),
        )
      | None =>
        log.warn(~comp="Platform", "heartbeat EP channel has no resources")
      }
    },

    // Phase 4 + 5: wire StateTopic and EventLogSubscription Lambdas per plugin.
    // Only active when the Events API resource exists (platform/monolithic mode).
    subscriptionInfraHook: ?domainEventsApiOpt->Option.map(eventsApi =>
      (params: ReventlessCore.Plugin_Helpers.subscriptionInfraParams) => {
        let {allQueryDbs, allEventTopics, eventLogEntries, opts} = params
        let customOpts =
          opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
        // StateTopic Lambda per stream-enabled QueryDb — publishes row changes
        // to AppSync Events channels.  No GraphQL Subscription resolver is
        // wired: Source B uses the Events WebSocket directly, not @aws_subscribe.
        allQueryDbs->Dict.forEachWithKey((_queryDbOutputs, readModelName) => {
          if QueryDbStorage_DynamoDbStream.streamRegistry->Set.has(readModelName) {
            // Channel root MUST equal what the host-shell subscribes to. The
            // AutoUI manifest sets queryableDef.queryField = listFieldName
            // (plural, e.g. "Catalog_Products") and AutoLive subscribes on that.
            // Publishing on the singular returnTypeName ("Catalog_Product")
            // would land descriptors on a channel no client listens to.
            let topicName =
              ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry
              ->Dict.get(readModelName)
              ->Option.map(qn => qn.listFieldName)
              ->Option.getOr(readModelName)
            StateTopic_AppSync.make(
              ~readModelName,
              ~topicName,
              ~allQueryDbs,
              ~eventsApi,
              ~opts=customOpts,
            )
          }
        })

        // Phase 5: EventLogSubscription per SNS-backed event log entry.
        // DynamoDB stream event topics (Category, DCB) are skipped — no SNS subscription needed.
        eventLogEntries->Array.forEach(entry => {
          // Aggregate EventTopics are keyed by Spec.name (= displayName).
          // DCB EventTopic is keyed by busKey (= pluginName ++ "DcbEventLog").
          let isSns =
            EventTopicPublisher_SNS.snsRegistry->Set.has(entry.displayName) ||
            EventTopicPublisher_SNS.snsRegistry->Set.has(entry.busKey)
          let eventTopicOutputs =
            isSns
              ? allEventTopics
                ->Dict.get(entry.displayName)
                ->Option.orElse(allEventTopics->Dict.get(entry.busKey))
              : None
          eventTopicOutputs->Option.forEach(outputs =>
            EventLogSubscription_AppSync.make(
              ~name=entry.displayName,
              ~topicName=entry.displayName,
              ~eventTopicOutputs=outputs,
              ~eventsApi,
              ~opts=customOpts,
            )
          )
        })
        // Finalize the shared StateTopic Lambda + IAM + per-stream ESMs from the
        // entries the loop above just registered. Must run INSIDE this hook because
        // Plugin_Builder fires it from inside a Pulumi.Output.apply chain — calling
        // `finish` from deployPlugin (after P.make returns) would see the registry
        // empty because the hook hasn't run yet. Admin's hook fires synchronously,
        // but the call site is unified here so admin and plugins share one path.
        StateTopic_AppSync.finish(~eventsApi, ~opts={})
      }
    ),
  }

  // Apply Plugin functor with the platform hooks, then constrain the result to Plugin.T.
  module PluginBuilderImpl = Plugin.Make({let hooks = hooks})
  module Plugin: ReventlessInfra.Plugin.T
    with type api = Types.AppSync.api
    and type role = Types.AppSync.role
    and type component = ReventlessCore.Plugin.component = {
    type api = Types.AppSync.api
    type role = Types.AppSync.role
    type component = ReventlessCore.Plugin.component
    let make = PluginBuilderImpl.make
    let makeAutoUIManifest = PluginBuilderImpl.makeAutoUIManifest
    let makePluginDefinition = PluginBuilderImpl.makePluginDefinition
  }

  module RuntimeEnvironment = RuntimeEnvironment.Lambda
  module EventCollectorChannel = EventCollectorChannel.SQS
  module Admin = ReventlessCore.Platform_Admin.Make(
    RuntimeEnvironment,
    EventCollectorChannel,
    QueryEngine.DynamoDb,
    ClonerRunner.Fargate,
    PluginRuntime_Builder.Make(EventCollectorChannel),
    DcbEventLogStorage.Selectable,
    EventTopicPublisher.DynamoDbStream,
    CommandTopicChannel.SQS_Sync,
    CommandTopicChannel.SQS_Async,
    {
      let silent = false
      let splitApi = Config.splitApi
      let cloner = Config.cloner
      let hooks = hooks
    },
  )

  // Admin-internal Plugin aggregate — standalone component so the PluginExtensionPoint
  // can publish commands to it and its infrastructure appears in stack outputs.
  // Uses the standard `Aggregate_Builder_Single` so admin-facing variants of
  // `PluginSpec.command` (Activate / Deactivate) are exposed as AppSync mutations
  // via the auto-resolver flow. Internal-protocol variants (Heartbeat, Connect,
  // Disconnect, ReportIncompatibility) carry `@noApi` and are filtered out before
  // SDL/resolver generation.
  module PluginAggregate: (
    ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
  ) = Aggregate_Builder_Single.Make(
    ReventlessCore.PluginSpec,
    ReventlessCore.PluginBehavior,
    ReventlessInfra.NoEventMappings.Make(ReventlessCore.PluginSpec),
  )

  // Admin-internal Plugin read model — standalone component for the Plugin QueryDb
  // (DynamoDB table) that backs queryEngine.scan(~readModelName="Plugins", ...).
  module PluginReadModelMappings: Reventless.Projection.Mappings
    with module Target := ReventlessCore.PluginsReadModelSpec = {
    // Reuse the already-instantiated Mappings from PluginsProjection so the Mapping
    // module type is the same nominal type — no coercion needed.
    module M = ReventlessCore.PluginsProjection.Mappings
    module type Mapping = M.Mapping
    // moduleUrl points at PluginsProjection.res.mjs (the file that exports `mappings`),
    // NOT this Platform.res file — the bundled ReadModel Lambda dynamic-imports this URL
    // at cold start, and Platform.res transitively imports @pulumi/aws (deploy-time only).
    let moduleUrl: string = ReventlessCore.PluginsProjection.moduleUrl
    let mappings: array<module(Mapping)> = ReventlessCore.PluginsProjection.mappings
  }

  // Standard ReadModel builder — attaches AppSync DynamoDB resolvers to the
  // admin-prefixed `Platform_Plugin` / `Platform_Plugins` SDL fields declared by
  // PluginBaseFragment.queryEntries. Field-name alignment is handled by the
  // queryFieldNamesRegistry entries that Platform_Admin.construct populates
  // from AdminApi.queryEntries before this builder runs.
  module PluginReadModel = ReadModel_Builder_Single_Stream.Make(
    ReventlessCore.PluginsReadModelSpec,
    PluginReadModelMappings,
  )

  // Admin-internal UIFragmentRegistry read model — projects UIFragmentRegistered/
  // Updated/Deregistered events from the Plugin aggregate into a DynamoDB table the
  // Platform_UIFragments admin query Lambda scans.
  module UIFragmentRegistryReadModelMappings: Reventless.Projection.Mappings
    with module Target := ReventlessCore.UIFragmentRegistryReadModelSpec = {
    module M = ReventlessCore.UIFragmentRegistryProjection.Mappings
    module type Mapping = M.Mapping
    // See PluginReadModelMappings.moduleUrl note above.
    let moduleUrl: string = ReventlessCore.UIFragmentRegistryProjection.moduleUrl
    let mappings: array<module(Mapping)> = ReventlessCore.UIFragmentRegistryProjection.mappings
  }

  module UIFragmentRegistryReadModel = ReadModel_Builder_NoResolver_Stream.Make(
    ReventlessCore.UIFragmentRegistryReadModelSpec,
    UIFragmentRegistryReadModelMappings,
  )

  module type PluginMaker = {
    let make: unit => Plugin.component
  }

  let makeScheduler = () => {
    let component = Scheduler.make()
    // Surface the IAM role ARN so bundled Task Lambdas can call PutRule with
    // the right `roleArn`. ScheduledPublisher_CloudWatchEvents stashes it as
    // `outputs.resource.urn` (no dedicated field on Scheduler.outputs).
    let outputs = component->ReventlessCore.Component.outputs
    hooks.schedulerRoleUrn := outputs.resource.urn
    component->ReventlessCore.Component.operations
  }

  type mcpSupported = | @as(true) McpSupported | @as(false) McpNotSupported
  let mcpSupported = McpNotSupported

  // B2.3d: provision the Postgres change-feed relay when a Postgres backend is
  // active. Called after plugins are built (makePlatform monolithic, or deployPlugin
  // per stack). Each Postgres log registered itself during its plugin build
  // (DcbEventLogStorage_Postgres.make / EventLogStorage_Postgres.make), and its
  // plugin's EventCollector queue was attached in forPluginEventCollector — so the
  // registries are complete here. One shared relay Lambda drains all logs (DCB and
  // classic) and feeds each plugin's collector queue. The checkpoint tables key by
  // subscriber alone, so the subscriber embeds the log name — a shared subscriber
  // string across logs would clobber checkpoints and skip events.
  let provisionPgChangeFeedRelay = () => {
    // B3.0: besides each plugin's EventCollector queue, every log also fans out
    // to the registered projection feed queues (the AllReadModels /
    // AllStateViewSlices Lambdas) — Postgres logs have no DynamoDB stream, so
    // this is how RM/SVS projections are fed. One subscriber per (feed, log)
    // keeps checkpoints isolated.
    let feedTargets = (~connectionConfig, ~logName, ~feed, ~isClassic) =>
      PgProjectionFeed.getFeedQueues()->Array.filterMap(fq =>
        (isClassic ? fq.includeClassic : fq.includeDcb)
          ? Some({
              PgChangeFeedRelay_Builder.connectionConfig,
              logName,
              subscriber: `${fq.scope}:${logName}`,
              feed,
              targetQueueUrl: fq.url,
              targetQueueArn: fq.arn,
            })
          : None
      )
    let dcbLogs = switch DcbBackend.get() {
    | Some({connectionConfig}) =>
      DcbBackend.getRelayLogs()->Array.flatMap(entry => {
        let feed = PgChangeFeedRelay_Builder.Dcb({partitionTag: entry.partitionTag})
        let ecTarget = switch (entry.collectorQueueUrl, entry.collectorQueueArn) {
        | (Some(targetQueueUrl), Some(targetQueueArn)) => [
            {
              PgChangeFeedRelay_Builder.connectionConfig,
              logName: entry.logName,
              subscriber: `aws-eventcollector-relay:${entry.logName}`,
              feed,
              targetQueueUrl,
              targetQueueArn,
            },
          ]
        | _ =>
          log.warn(
            ~comp="Platform",
            `PgChangeFeedRelay: DCB log ${entry.logName} has no EventCollector queue — EP/extension fan-out skipped for it`,
          )
          []
        }
        ecTarget->Array.concat(
          feedTargets(~connectionConfig, ~logName=entry.logName, ~feed, ~isClassic=false),
        )
      })
    | None => []
    }
    let classicLogs = switch EventLogBackend.get() {
    | Some({connectionConfig}) =>
      EventLogBackend.getRelayLogs()->Array.flatMap(entry => {
        let feed = PgChangeFeedRelay_Builder.Classic
        let ecTarget = switch (entry.collectorQueueUrl, entry.collectorQueueArn) {
        | (Some(targetQueueUrl), Some(targetQueueArn)) => [
            {
              PgChangeFeedRelay_Builder.connectionConfig,
              logName: entry.logName,
              subscriber: `aws-eventcollector-relay:${entry.logName}`,
              feed,
              targetQueueUrl,
              targetQueueArn,
            },
          ]
        | _ =>
          log.warn(
            ~comp="Platform",
            `PgChangeFeedRelay: classic log ${entry.logName} has no EventCollector queue — EP/extension fan-out skipped for it`,
          )
          []
        }
        ecTarget->Array.concat(
          feedTargets(~connectionConfig, ~logName=entry.logName, ~feed, ~isClassic=true),
        )
      })
    | None => []
    }
    let relayLogs = dcbLogs->Array.concat(classicLogs)
    let relayVpc = switch DcbBackend.get() {
    | Some(sel) => Some((sel.securityGroupId, sel.subnetIds))
    | None =>
      switch EventLogBackend.get() {
      | Some(sel) => Some((sel.securityGroupId, sel.subnetIds))
      | None => None
      }
    }
    switch relayVpc {
    | Some((securityGroupId, subnetIds)) =>
      if relayLogs->Array.length > 0 {
        let _ = PgChangeFeedRelay_Builder.make(
          ~name="PgChangeFeedRelay",
          ~logs=relayLogs,
          ~securityGroupId,
          ~subnetIds,
        )
      }
    | None => ()
    }
  }

  // In split mode, create a dedicated core AppSync API and push the core schema.
  // In unified mode, makePlatform is a no-op (schema stitching handled by events).
  let makePlatform = (~version, ~plugins: array<module(PluginMaker)>) => {
    log.info(~comp="Platform", `v${version}`)
    // Create scheduler and populate platform context refs so Plugin_Builder
    // can read them without app plugins having to pass them through.
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some(domainApi->wrapHookedValue)
    hooks.apiRole := Some(domainApiRole->wrapHookedValue)

    // Phase 2: create the Platform API resource early — before Admin.construct —
    // so admin resolvers are attached to the correct API in split mode.
    // In unified mode this is the same resource as the Domain API.
    let (platformApi, platformApiRole) = if Config.splitApi {
      AppSync_Adapter.makeApiResource(~name="PlatformApi", ~opts={})
    } else {
      (domainApi, domainApiRole)
    }

    // Update splitApiOutputsRef and apiConfig with the now-known Platform API.
    if Config.splitApi {
      splitApiOutputsRef := Some({platformApi, platformApiRole})
      switch apiConfigRef.contents {
      | Some(c) =>
        apiConfigRef := Some({
          domainApi: c.domainApi,
          domainApiRole: c.domainApiRole,
          platformApi: platformApi,
          platformApiRole: platformApiRole,
        })
      | None => ()
      }
    }

    // Phase 2: Admin resolvers go on the Platform API (platformApi) in split mode,
    // on the shared Domain API in unified mode.
    let admin = Admin.construct(
      ~version,
      ~extensionPoints=[],
      ~aggregates=[module(PluginAggregate)],
      ~readModels=[
        module(PluginReadModel),
        module(UIFragmentRegistryReadModel),
      ],
      ~scheduler,
      ~resourceNaming=Util_ResourceNaming.operations,
      ~api=platformApi,
      ~apiRole=platformApiRole,
      ~stateChangeSlices=[],
      ~stateViewSlices=[],
      ~automationSlices=[],
      ~outboundTranslationSlices=[],
      ~inboundTranslationSlices=[],
    )

    // Mount the Platform_ComponentDefinitions Lambda resolver on the Platform API
    // (split mode) or Domain API (unified mode — platformApi == domainApi above).
    // Also register the Plugin RM table with the AllAggregates Lambda runtime
    // so its in-Lambda plugin status gate can read plugin status at command
    // dispatch time (Part 2.3 of the resolver plan).
    switch admin.readModelsOutputs->Dict.get("Plugins") {
    | Some(pluginRm) =>
      switch pluginRm.queryDb.resources->Array.get(0) {
      | Some(r) =>
        Platform_ComponentDefinitions_Lambda.make(
          ~api=platformApi,
          ~pluginReadModelTableName=r.name,
          ~opts={},
        )
        AggregateRuntime_Builder_Single.setPluginReadModelTable(~name=r.name)
      | None => ()
      }
    | None => ()
    }

    // Mount the Platform_UIFragments Lambda resolver — scans the UIFragmentRegistry
    // table provisioned above and returns one entry per registered plugin UI.
    switch admin.readModelsOutputs->Dict.get("UIFragmentRegistry") {
    | Some(rm) =>
      switch rm.queryDb.resources->Array.get(0) {
      | Some(r) =>
        Platform_UIFragments_Lambda.make(
          ~api=platformApi,
          ~uiFragmentRegistryTableName=r.name,
          ~opts={},
        )
      | None => ()
      }
    | None => ()
    }

    // Build each plugin.
    let pluginComponents = plugins->Array.map(plugin => {
      module P = unpack(plugin)
      P.make()
    })

    // Note: StateTopic_AppSync.finish runs from inside subscriptionInfraHook
    // (Phase 4 wiring above), not here — Plugin_Builder fires the hook from
    // within a Pulumi.Output.apply chain, so finishing synchronously here would
    // see an empty registry.

    // Export first plugin's outputs (monolithic mode = typically single plugin).
    switch pluginComponents->Array.get(0) {
    | Some(pluginComponent) =>
      let pluginOutputs = pluginComponent->ReventlessCore.Component.outputs
      ReventlessCore.Plugin_Helpers.exportPluginOutputs(pluginOutputs)
    | None => ()
    }

    // B2.3d: provision the Postgres change-feed relay (monolithic mode — all plugins
    // built above, so the DcbBackend relay registry is complete).
    provisionPgChangeFeedRelay()

    // B3.2b: provision the shared PgQueryResolver Lambda + AppSync data source for
    // Postgres-backed read models (monolithic mode). Runs after construct so the
    // resolver-binding registry (QueryDbResolvers_Lambda.make) and the ReadModel
    // spec-module registry are complete; it fulfils the deferred `dataSourceName`
    // the Postgres storage maker handed to the (schema-pushed) resolvers. App read
    // model resolvers attach to the Domain API. Plugin-stack mode is deferred —
    // it needs a per-stack data-source name to avoid collisions on the shared API.
    switch QueryDbBackend.get() {
    | Some(sel) => PgQueryResolver_Builder.provision(~api=domainApi, ~selection=sel, ~opts={})
    | None => ()
    }

    // Admin schema push is fired by preAdminResolversSchemaHook from inside
    // Admin.construct (with createResolvers gated on it). Only exports below.
    if Config.splitApi {
      // Platform API exports (split mode).
      Pulumi.Pulumi.export("platformApiId", platformApi->Pulumi.Output.flatMap(api => api.id))
      Pulumi.Pulumi.export(
        "platformApiEndpoint",
        platformApi->Pulumi.Output.flatMap(api =>
          api.uris->Pulumi.Output.apply(uris => uris.graphQL)
        ),
      )
      Pulumi.Pulumi.export("platformApiRoleArn", platformApiRole->Pulumi.Output.flatMap(role => role.arn))
    } else {
      // Platform API exports (unified mode — same resource as Domain API).
      Pulumi.Pulumi.export("platformApiId", domainApi->Pulumi.Output.flatMap(api => api.id))
      Pulumi.Pulumi.export(
        "platformApiEndpoint",
        domainApi->Pulumi.Output.flatMap(api =>
          api.uris->Pulumi.Output.apply(uris => uris.graphQL)
        ),
      )
      Pulumi.Pulumi.export("platformApiRoleArn", domainApiRole->Pulumi.Output.flatMap(role => role.arn))
    }

    // Domain API exports.
    Pulumi.Pulumi.export("domainApiId", domainApi->Pulumi.Output.flatMap(api => api.id))
    Pulumi.Pulumi.export(
      "domainApiEndpoint",
      domainApi->Pulumi.Output.flatMap(api =>
        api.uris->Pulumi.Output.apply(uris => uris.graphQL)
      ),
    )
    Pulumi.Pulumi.export("domainApiRoleArn", domainApiRole->Pulumi.Output.flatMap(role => role.arn))
  }

  // Optional host UI shell bundle: a static SPA (e.g. reventless-ui's host-shell)
  // hosted on the platform's CloudFront-fronted S3 bucket. The platform writes a
  // `config.json` next to `index.html` so the shell discovers `apiEndpoint` and
  // `region` at boot without rebuild.
  type hostUiBundleConfig = {
    assetsDir: string,
    bundleVersion: string,
  }

  let deployPlatform = (~version, ~hostUiBundle: option<hostUiBundleConfig>=?) => {
    log.info(~comp="Platform:deployPlatform", `v${version}`)
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some(domainApi->wrapHookedValue)
    hooks.apiRole := Some(domainApiRole->wrapHookedValue)

    // Phase 2: create the Platform API resource early — before Admin.construct —
    // so admin resolvers are attached to the correct API in split mode.
    // In unified mode this is the same resource as the Domain API.
    let (platformApi, platformApiRole) = if Config.splitApi {
      AppSync_Adapter.makeApiResource(~name="PlatformApi", ~opts={})
    } else {
      (domainApi, domainApiRole)
    }

    // Update splitApiOutputsRef and apiConfig with the now-known Platform API.
    if Config.splitApi {
      splitApiOutputsRef := Some({platformApi, platformApiRole})
      switch apiConfigRef.contents {
      | Some(c) =>
        apiConfigRef := Some({
          domainApi: c.domainApi,
          domainApiRole: c.domainApiRole,
          platformApi: platformApi,
          platformApiRole: platformApiRole,
        })
      | None => ()
      }
    }

    // Create PluginExtensionPoint with runtime schema stitching.
    // When plugins connect/disconnect, the handler queries the Plugin read model
    // for all active schema fragments, stitches them with the admin base, and
    // pushes the combined schema to AppSync via the SDK.
    //
    // The closure captures domainApiId (a Pulumi Output). Pulumi serializes
    // captured Outputs into the CallbackFunction Lambda; at runtime, Output.get
    // returns the resolved string synchronously.
    let domainApiId = domainApi->Pulumi.Output.flatMap(api => api.id)

    module PluginExtensionPoint = Plugin_ExtensionPoint_Builder.MakeWithConfig({
      // Cross-plugin SNS subscription management runs in the bundled
      // AdminEventCollector Lambda (AdminEventCollectorEntryPoint.mjs), not in
      // this deploy-time EP Lambda — which only handles incoming commands
      // (Heartbeat, ForwardCommand). None here keeps the deploy-time path
      // unchanged; the .mjs entry point supplies a real implementation.
      let manageSubscriptions = None
      let updateApiSchema = Some(async (queryEngine: Reventless.QueryEngine.operations) => {
        open Reventless.QueryEngine.Filter
        let apiId = domainApiId->Pulumi.Output.get
        let plugins = await queryEngine.scan(
          ~readModelName="Plugins",
          ~filterConfigs=[("status", Contains, String("Connected"))],
          ~limit=1000,
        )
        let fragments = plugins->Array.filterMap(json =>
          try {
            let state = json->S.parseOrThrow(ReventlessCore.PluginsReadModelSpec.stateSchema)
            // Exclude Platform-target plugins — their schema belongs on the PlatformApi,
            // not the DomainApi. Absent apiTarget defaults to "Domain".
            switch state.apiTarget {
            | Some("Platform") => None
            | _ => state.apiSchemaFragment
            }
          } catch {
          | _ => None
          }
        )
        // In split mode, the plugin API only has plugin schema (admin is on the core API).
        // In unified mode, stitch admin + plugins into the single shared API.
        let baseFragment = if Config.splitApi {
          emptyBaseFragment
        } else {
          AppSync_Adapter.injectAwsAuthAll(
            ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
            ~group="Admin",
          )
        }
        let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
          ~baseFragment,
          ~pluginFragments=fragments,
        )
        await AppSync_Adapter.getClient()->AppSync_Adapter.startSchemaCreationRetrying({
          apiId,
          definition: sdl,
        })
      })
    })

    // Phase 2: Admin resolvers go on the Platform API (platformApi) in split mode,
    // on the shared Domain API in unified mode.
    let admin = Admin.construct(
      ~version,
      ~extensionPoints=[module(PluginExtensionPoint)],
      ~aggregates=[module(PluginAggregate)],
      ~readModels=[
        module(PluginReadModel),
        module(UIFragmentRegistryReadModel),
      ],
      ~scheduler,
      ~resourceNaming=Util_ResourceNaming.operations,
      ~api=platformApi,
      ~apiRole=platformApiRole,
      ~stateChangeSlices=[],
      ~stateViewSlices=[],
      ~automationSlices=[],
      ~outboundTranslationSlices=[],
      ~inboundTranslationSlices=[],
    )

    // Extract Plugin RM table name as Output.t<string>.
    // IMPORTANT: Do NOT use option<Pulumi.Output.t<…>> — Pulumi Outputs use property
    // lifting, which breaks ReScript's internal option encoding (BS_PRIVATE_NESTED_SOME_NONE).
    // Instead, use Output.t<string> with a placeholder for "not available".
    let pluginReadModelTableName = switch admin.readModelsOutputs->Dict.get("Plugins") {
    | Some(pluginRm) =>
      switch pluginRm.queryDb.resources->Array.get(0) {
      | Some(r) => Some(r.name)
      | None => None
      }
    | None => None
    }

    // Dedicated DynamoDB table for deploy-time schema-fragment persistence
    // (deploy-schema:<name>, deploy-schema-platform:<name>, deploy-schema-hash:<apiId>).
    // Previously these infrastructure rows shared the Plugin RM table, which
    // caused them to leak through Platform_Plugins' auto-generated AppSync
    // Connection resolver (an unfiltered Scan). Hosting them on their own
    // table keeps Plugin RM = Plugin aggregate entities only and restores
    // parity with the in-memory adapter (which has no preResolversSchemaHook).
    let pluginSchemaPersistenceTable = Util.DynamoDb.makeTable(
      "PluginSchemaPersistence",
      ~attributes=[{name: "id", type_: "S"}],
      ~opts={},
    )

    PluginExtensionPointRuntime_Builder.registerPluginExtensionPoint(
      ~pluginReadModelTableName?,
      ~schedulerRoleArn=hooks.schedulerRoleUrn.contents,
      (),
    )

    // Extract the Plugin ExtensionPoint's EventTopic (SNS) ARN so the
    // AdminEventCollector runtime can publish outgoing EP events (e.g.
    // UnknownPluginDetected). Without this, AdminEventColl's HANDLER_CONFIG
    // carries eventTopicArn="NOT_AVAILABLE" and the SNS publish silently
    // targets a non-existent ARN, breaking the
    // admin → plugin EventCollector → ConnectPlugin round-trip and leaving
    // the Plugin read model empty.
    let pluginEpEventTopicArn =
      admin.extensionPointsOutputs->Pulumi.Output.flatMap(eps =>
        switch eps->Array.find(ep =>
          ep.name == ReventlessInfra.PluginExtensionPointSpec.name
        ) {
        | Some(ep) =>
          ep.eventTopic->Pulumi.Output.flatMap(et =>
            switch et.resources->Array.get(0) {
            | Some(r) => r.urn
            | None => Pulumi.Output.make("NOT_AVAILABLE")
            }
          )
        | None => Pulumi.Output.make("NOT_AVAILABLE")
        }
      )

    PluginRuntime_Builder.registerConfig(
      ~eventTopicArn=pluginEpEventTopicArn,
      ~appSyncApiId=domainApiId,
      ~pluginReadModelTableName?,
      // Runtime schema stitch reads deploy-time fragments from this durable table
      // rather than the lifecycle-volatile Plugin RM Connected rows.
      ~pluginSchemaPersistenceTableName=pluginSchemaPersistenceTable.name,
      ~schedulerRoleArn=hooks.schedulerRoleUrn.contents,
      ~clonerEnabled=Config.cloner,
      (),
    )

    // Mount the Platform_ComponentDefinitions Lambda resolver on the Platform API
    // (split mode) or Domain API (unified mode — platformApi == domainApi above).
    // Also register the Plugin RM table with the AllAggregates Lambda runtime
    // so its in-Lambda plugin status gate can read plugin status at command
    // dispatch time (Part 2.3 of the resolver plan).
    switch pluginReadModelTableName {
    | Some(tableName) =>
      AggregateRuntime_Builder_Single.setPluginReadModelTable(~name=tableName)
      Platform_ComponentDefinitions_Lambda.make(
        ~api=platformApi,
        ~pluginReadModelTableName=tableName,
        ~opts={},
      )
    | None => ()
    }

    // Mount the Platform_UIFragments Lambda resolver — scans the UIFragmentRegistry
    // table provisioned above and returns one entry per registered plugin UI.
    switch admin.readModelsOutputs->Dict.get("UIFragmentRegistry") {
    | Some(rm) =>
      switch rm.queryDb.resources->Array.get(0) {
      | Some(r) =>
        Platform_UIFragments_Lambda.make(
          ~api=platformApi,
          ~uiFragmentRegistryTableName=r.name,
          ~opts={},
        )
      | None => ()
      }
    | None => ()
    }

    // Note: StateTopic_AppSync.finish runs from inside subscriptionInfraHook
    // (Phase 4 wiring above), not here — see the note in deployPlatform.

    // Admin schema push is fired by preAdminResolversSchemaHook from inside
    // Admin.construct (gated on a read-model-resources barrier, with admin
    // createResolvers chained behind the resulting Output). Only exports below.
    if Config.splitApi {
      // Platform API exports (split mode).
      Pulumi.Pulumi.export("platformApiId", platformApi->Pulumi.Output.flatMap(api => api.id))
      Pulumi.Pulumi.export(
        "platformApiEndpoint",
        platformApi->Pulumi.Output.flatMap(api =>
          api.uris->Pulumi.Output.apply(uris => uris.graphQL)
        ),
      )
      Pulumi.Pulumi.export("platformApiRoleArn", platformApiRole->Pulumi.Output.flatMap(role => role.arn))
    } else {
      // Platform API exports (unified mode — same resource as Domain API).
      Pulumi.Pulumi.export("platformApiId", domainApi->Pulumi.Output.flatMap(api => api.id))
      Pulumi.Pulumi.export(
        "platformApiEndpoint",
        domainApi->Pulumi.Output.flatMap(api =>
          api.uris->Pulumi.Output.apply(uris => uris.graphQL)
        ),
      )
      Pulumi.Pulumi.export("platformApiRoleArn", domainApiRole->Pulumi.Output.flatMap(role => role.arn))
    }

    // Domain API exports.
    Pulumi.Pulumi.export("domainApiId", domainApi->Pulumi.Output.flatMap(api => api.id))
    Pulumi.Pulumi.export(
      "domainApiEndpoint",
      domainApi->Pulumi.Output.flatMap(api =>
        api.uris->Pulumi.Output.apply(uris => uris.graphQL)
      ),
    )
    Pulumi.Pulumi.export("domainApiRoleArn", domainApiRole->Pulumi.Output.flatMap(role => role.arn))

    // Events API exports — consumed by plugin stacks to wire Source B (StateTopic) Lambdas.
    switch domainEventsApiOpt {
    | Some(eventsApi) =>
      Pulumi.Pulumi.export("eventsApiArn", eventsApi.api.apiArn)
      Pulumi.Pulumi.export(
        "eventsApiDns",
        eventsApi.api.dns->Pulumi.Output.apply(dns => dns.http->Option.getOr("")),
      )
    | None => ()
    }

    // Export Plugin RM table name so plugin stacks can query existing plugins
    // for cumulative schema stitching (preResolversSchemaHook).
    switch pluginReadModelTableName {
    | Some(tableName) => Pulumi.Pulumi.export("pluginRmTableName", tableName)
    | None => ()
    }

    // Export the dedicated schema-persistence table name. preResolversSchemaHook
    // prefers this over pluginRmTableName so deploy-schema rows no longer share
    // the Plugin RM table.
    Pulumi.Pulumi.export(
      "pluginSchemaPersistenceTableName",
      pluginSchemaPersistenceTable.name,
    )

    // (No pluginAggrCmdTopicUrl export: the deploy-time retire hook that
    // published Retire commands to the Plugin aggregate queue is gone —
    // supersession is decided by the aggregate on connect.)

    // Export admin component outputs (same pattern as deployPlugin).
    ReventlessCore.Plugin_Helpers.exportPlatformOutputs(
      ~extensionPointsOutputs=admin.extensionPointsOutputs,
      ~aggregatesOutputs=admin.aggregatesOutputs,
      ~readModelsOutputs=admin.readModelsOutputs,
      ~dcbEventLogOutputs=admin.dcbEventLogOutputs,
      ~stateChangeSlicesOutputs=admin.stateChangeSlicesOutputs,
      ~stateViewSlicesOutputs=admin.stateViewSlicesOutputs,
      ~automationSlicesOutputs=admin.automationSlicesOutputs,
      ~outboundTranslationSlicesOutputs=admin.outboundTranslationSlicesOutputs,
      ~inboundTranslationSlicesOutputs=admin.inboundTranslationSlicesOutputs,
    )

    // Fire onPlatformDeployed hook with resolved platform metadata.
    let resolvedDomainApiEndpoint = domainApi->Pulumi.Output.flatMap(api =>
      api.uris->Pulumi.Output.apply(uris => uris.graphQL)
    )
    let resolvedDomainApiRoleArn = domainApiRole->Pulumi.Output.flatMap(role => role.arn)
    let resolvedPlatformApiEndpoint = platformApi->Pulumi.Output.flatMap(api =>
      api.uris->Pulumi.Output.apply(uris => uris.graphQL)
    )
    let resolvedPlatformApiRoleArn = platformApiRole->Pulumi.Output.flatMap(role => role.arn)
    // Collect admin aggregate + read model resources.
    let adminResourcesOutput =
      admin.aggregatesOutputs
      ->Dict.valuesToArray
      ->Array.map(agg =>
        agg
        ->ReventlessCore.Aggregate.toResolvedOutputs
        ->Pulumi.Output.apply((r: ReventlessInterop.Aggregate.resolvedOutputs) =>
          Array.flat([
            r.eventLog.resources,
            r.eventLog.eventTopic.resources,
            r.commandTopic.resources,
            r.commandGenerator.resources,
          ])
        )
      )
      ->Array.concat(
        admin.readModelsOutputs
        ->Dict.valuesToArray
        ->Array.map(rm =>
          rm
          ->ReventlessCore.ReadModel.toResolvedOutputs
          ->Pulumi.Output.apply((r: ReventlessInterop.ReadModel.resolvedOutputs) =>
            r.queryDb.resources
          )
        ),
      )
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(arrays => Array.flat(arrays))
    let _ =
      (
        resolvedDomainApiEndpoint,
        resolvedDomainApiRoleArn,
        resolvedPlatformApiEndpoint,
        resolvedPlatformApiRoleArn,
        adminResourcesOutput,
      )
      ->Pulumi.Output.all5
      ->Pulumi.Output.apply(((domainApiEndpoint, domainApiRoleArn, platformApiEndpoint, platformApiRoleArn, adminResources)) => {
        let region =
          Pulumi.Config.make(Some("aws"))->Pulumi.Config.get("region")->Option.getOr("unknown")
        ReventlessCore.Plugin_Helpers.firePlatformDeployedHook({
          name: Pulumi.Pulumi.getProjectName(),
          environment: Pulumi.Pulumi.getStackName(),
          region,
          domainApiEndpoint,
          domainApiRoleArn,
          platformApiEndpoint,
          platformApiRoleArn,
          adminResources,
        })
      })

    // Host UI shell deployment — opt-in via ~hostUiBundle. The shell SPA is
    // hosted on its own CloudFront distribution; `config.json` is generated
    // at deploy time with the resolved API endpoints, region, and Cognito
    // pool/client IDs so the shell can boot without knowing them at build
    // time. `authMode: "cognito"` matches the AppSync auth wiring established
    // by Stage D (Auth_Cognito.make). Cognito values come from the
    // process-cached `Platform_Stack.resolveCognitoUserPool` so no extra
    // resources or stack exports are introduced here.
    switch hostUiBundle {
    | None => ()
    | Some(cfg) =>
      // Auto-derive the host-shell FQDN when both `hostUiBaseDomain` and
      // `hostUiHostedZoneId` are configured (env var → `Pulumi.local.yaml` →
      // `Pulumi.<stack>.yaml`). When either is missing the framework keeps the
      // default *.cloudfront.net URL — no surprise opt-in. See
      // [docs/plans/done/host-ui-custom-domain.md].
      let customDomain = switch (
        Util_LocalConfig.get("hostUiBaseDomain"),
        Util_LocalConfig.get("hostUiHostedZoneId"),
      ) {
      | (Some(bd), Some(hz)) =>
        let stack = Pulumi.Pulumi.getStackName()
        let baseName =
          Util_LocalConfig.get("hostUiBaseName")->Option.getOr(Pulumi.Pulumi.getProjectName())
        let prodStacks =
          Util_LocalConfig.get("hostUiProdStacks")
          ->Option.map(Util_HostUiDomain.parseProdStacks)
          ->Option.getOr(Util_HostUiDomain.defaultProdStacks)
        let fqdn = Util_HostUiDomain.deriveFqdn(
          ~baseName,
          ~stack,
          ~baseDomain=bd,
          ~prodStacks,
        )
        Some({Plugin_Stack.fqdn, hostedZoneId: hz})
      | _ => None
      }

      let {distributionUrl, bucketName} = Plugin_Stack.makeUiBundleDistribution(
        ~pluginId="host-ui",
        ~bundleVersion=cfg.bundleVersion,
        ~assetsDir=cfg.assetsDir,
        ~spaFallback=true,
        ~stableName=true,
        // The explicit BucketObject below writes the production config.json
        // with the resolved API endpoints + Cognito IDs. The host-shell
        // bundle's public/config.json is the dev-mode fallback — exclude
        // it from the bundle upload so both BucketObjects don't race on
        // the same S3 key.
        ~excludeFiles=["config.json"],
        ~customDomain?,
      )

      let regionStr =
        Pulumi.Config.make(Some("aws"))
        ->Pulumi.Config.get("region")
        ->Option.getOr("unknown")

      let cognitoPool = Platform_Stack.resolveCognitoUserPool()

      // AppSync Events API endpoint for live (real-time) read-model updates.
      // The UI's LiveConnection swaps the host to the realtime domain and appends
      // `/realtime`, so it expects the HTTPS `…/event` form. A single Events API
      // serves both domain and platform read-model channels, so both config
      // fields point at it. `liveUpdates: true` arms the client-side kill switch;
      // without these three fields LiveConnection.isLive is false and the UI
      // never subscribes (lists then only refresh on a full reload).
      let domainEventsEndpointOutput: Pulumi.Output.t<option<string>> = switch domainEventsApiOpt {
      | Some(eventsApi) =>
        AppSync_EventsApi.httpEndpoint(eventsApi)->Pulumi.Output.apply(ep => Some(ep ++ "/event"))
      | None => Pulumi.Output.make(None)
      }

      let configJsonContent =
        (
          (
            resolvedDomainApiEndpoint,
            resolvedPlatformApiEndpoint,
            cognitoPool.poolId,
            cognitoPool.clientId,
          )->Pulumi.Output.all4,
          domainEventsEndpointOutput,
        )
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply((((domainEp, platformEp, poolId, clientId), eventsEpOpt)) => {
          let fields = [
            ("apiEndpoint", JSON.Encode.string(domainEp)),
            ("platformApiEndpoint", JSON.Encode.string(platformEp)),
            ("region", JSON.Encode.string(regionStr)),
            ("authMode", JSON.Encode.string("cognito")),
            ("cognitoUserPoolId", JSON.Encode.string(poolId)),
            ("cognitoClientId", JSON.Encode.string(clientId)),
            ("liveUpdates", JSON.Encode.bool(true)),
          ]
          let withEvents = switch eventsEpOpt {
          | Some(ep) =>
            Array.concat(
              fields,
              [
                ("domainApiEventsEndpoint", JSON.Encode.string(ep)),
                ("platformApiEventsEndpoint", JSON.Encode.string(ep)),
              ],
            )
          | None => fields
          }
          withEvents->Dict.fromArray->JSON.Encode.object->JSON.stringify
        })

      let _ = PulumiAws.S3.BucketObject.make(
        ~name="host-ui-config-json",
        ~args={
          bucket: bucketName->Pulumi.Output.asInput,
          key: Pulumi.Input.make("config.json"),
          content: configJsonContent->Pulumi.Output.asInput,
          contentType: Pulumi.Input.make("application/json"),
        },
      )

      Pulumi.Pulumi.export("hostShellUrl", distributionUrl)
    }

    Pulumi.Pulumi.getOutputs()
  }

  let startServers = () => ()

  let deployPlugin = (~plugin: module(PluginMaker), ~apiTarget=Domain) => {
    log.info(
      ~comp="Platform:deployPlugin",
      `target=${switch apiTarget {
        | Domain => "Domain"
        | Platform => "Platform"
        }}`,
    )
    currentDeployTarget := apiTarget
    // Expose deploy target via hooks so Plugin_Builder can stamp pluginDefinition.apiTarget.
    // This must be set before P.make() and is captured synchronously by Plugin_Builder
    // (same timing requirement as hooks.api/apiRole).
    hooks.deployTarget := switch apiTarget { | Domain => "Domain" | Platform => "Platform" }
    // Each plugin stack creates its own scheduler (closures can't cross stacks).
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    let targetApi = resolveTargetApi()
    let targetApiRole = resolveTargetApiRole()
    hooks.api := Some(targetApi->wrapHookedValue)
    hooks.apiRole := Some(targetApiRole->wrapHookedValue)

    module P = unpack(plugin)
    let pluginComponent = P.make()
    currentDeployTarget := Domain // reset after build

    // Note: StateTopic_AppSync.finish runs from inside subscriptionInfraHook —
    // Plugin_Builder fires the hook from within a Pulumi.Output.apply chain, so
    // finishing here would see the registry empty (the hook hasn't fired yet
    // when P.make() returns).

    // Export interop metadata for cross-stack consumption.
    Pulumi.Pulumi.export("_interopMeta", ReventlessCore.Plugin_Helpers.getInteropMeta())

    // Export plugin outputs (plugin, tasks, eventMappers, extensionPoints) for cross-stack access.
    let pluginOutputs = pluginComponent->ReventlessCore.Component.outputs
    ReventlessCore.Plugin_Helpers.exportPluginOutputs(pluginOutputs)

    // B2.3d: provision the Postgres change-feed relay (plugin-stack mode — this
    // plugin's Postgres DCB log(s) + collector queue were registered during P.make()).
    provisionPgChangeFeedRelay()

    // B3.2b/c: provision this plugin stack's PgQueryResolver Lambda + AppSync data
    // source for its Postgres-backed read models (registered during P.make()). App
    // read model resolvers attach to the Domain API. Per-plugin Lambda + auto-named
    // data source, so plugin stacks don't collide. The node(id) resolver is skipped
    // in plugin-stack mode — it's a single shared Query.node field only one stack
    // may own (monolithic-only; see PgQueryResolver_Builder.provision).
    switch QueryDbBackend.get() {
    | Some(sel) =>
      PgQueryResolver_Builder.provision(
        ~api=domainApi,
        ~selection=sel,
        ~opts={},
        ~createNodeResolver=false,
      )
    | None => ()
    }

    // Zero-downtime handover (Part 3.1): fire ONE synthetic heartbeat for the
    // just-deployed plugin so its new version runs the connect handshake within
    // seconds instead of waiting for the CloudWatch heartbeat rule's first
    // natural tick (up to `heartbeatTimeout` minutes). Routes through the exact
    // runtime heartbeat path — a `Heartbeat(timeout)` command (id = name@version)
    // onto the EP FIFO command-topic queue — mirroring HeartbeatEntryPoint.mjs and
    // reusing CommandTopicChannel_SQS_Runtime.publishJsons (correct FIFO
    // message-group handling). If it no-ops (config missing / send fails) the
    // handover still completes on the next natural heartbeat — graceful degradation.
    // heartbeatConfigRef holds the just-built plugin's config (deployPlugin builds
    // exactly one plugin per call, and registerHeartbeatConfig ran during P.make()).
    let hbConfig = PluginRuntime_Builder.heartbeatConfigRef.contents
    switch (Pulumi.Pulumi.isDryRun(), hbConfig.epQueueUrl) {
    | (true, _) => () // `pulumi preview` — no deploy-time side effects
    | (false, Some(epQueueUrl)) =>
      let _ = epQueueUrl->Pulumi.Output.apply(async url => {
        let queue: Util_SQS_Runtime.resolvedQueue = {id: url, name: "", arn: ""}
        let publishHeartbeat = queue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO)
        let message: ReventlessCore.Message.commandJson = {
          id: hbConfig.pluginId,
          meta: ReventlessCore.Message.generateMeta(
            ~service=ReventlessInfra.PluginExtensionPointSpec.name,
            ~user="DeployHeartbeat",
          ),
          commandJson: ReventlessInfra.PluginExtensionPointSpec.Heartbeat(
            hbConfig.heartbeatTimeout,
          )->S.reverseConvertToJsonOrThrow(ReventlessInfra.PluginExtensionPointSpec.commandSchema),
        }
        try await publishHeartbeat([message]) catch {
        | _ =>
          log.warn(
            ~comp="Platform:deployPlugin",
            `synthetic heartbeat failed for ${hbConfig.pluginId} (handover falls back to the next natural heartbeat)`,
          )
        }
      })
    | (false, None) =>
      log.warn(
        ~comp="Platform:deployPlugin",
        "synthetic heartbeat skipped: no EP queue URL in heartbeat config",
      )
    }

    Pulumi.Pulumi.getOutputs()
  }
}

// Default platform — split API, no cloner, framework-default Lambda tuning.
module Make = (): (
  ReventlessInfra.Platform.T with type api = Types.AppSync.api and type role = Types.AppSync.role
) => {
  include MakeWithConfig({
    let splitApi = true
    let cloner = false
    let commandHandlerConfig: ReventlessCore.Runtime.commandHandlerConfigs = {}
    let pgConnection = None
  })
}
