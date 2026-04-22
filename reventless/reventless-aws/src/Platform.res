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
  },
): (
  ReventlessInfra.Platform.T with type api = Types.AppSync.api and type role = Types.AppSync.role
) => {
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
    | None => Some(AppSync_EventsApi.make(~name="DomainEventsApi", ~opts={}))
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
      Some({AppSync_EventsApi.api, defaultNamespace: None})
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
    // This Make satisfies Platform.T but registers no Lambda entry point.
    // For working AWS deployments, use the AWS builders directly
    // (e.g., ReventlessAws.Aggregate_Builder_Single.Make) from _Aws plugin variants.
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
        let moduleUrl = Spec.moduleUrl
        let mappings: array<module(Mapping)> = [module(CompiledMapping)]
      }
      module Inner = ExtensionPoint_Builder.Make(Spec, Mappings, {
        let publishToAggregatesQueueUrls = Dict.make()
      })
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
        let moduleUrl = Spec.moduleUrl
        let mappings: array<module(Mapping)> = [module(CM1), module(CM2)]
      }
      module Inner = ExtensionPoint_Builder.Make(Spec, Mappings, {
        let publishToAggregatesQueueUrls = Dict.make()
      })
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
        let moduleUrl = Spec.moduleUrl
        let mappings: array<module(Mapping)> = [module(CM1), module(CM2), module(CM3)]
      }
      module Inner = ExtensionPoint_Builder.Make(Spec, Mappings, {
        let publishToAggregatesQueueUrls = Dict.make()
      })
      include Inner
    }

    module MakeMulti = (
      Spec: ReventlessInfra.ExtensionPointMapping.Spec,
      Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
    ): ReventlessInfra.ExtensionPoint.T =>
      ExtensionPoint_Builder.Make(Spec, Mappings, {
        let publishToAggregatesQueueUrls = Dict.make()
      })
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
      let moduleUrl = Mapping.Delegate.moduleUrl
      let mappings: array<module(Mapping)> = [module(CompiledMapping)]
    }

  }

  module Task = {
    module Make = (Spec: ReventlessInfra.Task.Spec): (
      ReventlessInfra.Task.T with module Spec = Spec
    ) =>
      Task_Builder_PerBucket.Make(Spec, {
        let callbackModulePaths = Dict.make()
        let publishToAggregatesQueueUrls = Dict.make()
      })
  }

  module Counter = Counter_Builder.Make(ApiConfig, {
    let specModulePath = ""
    let mappingsModulePath = ""
    let publishQueueUrl = Pulumi.Output.make("")
  })

  module StateChangeSlice = {
    module Make = (Spec: Reventless.StateChangeSlice.Spec): (
      ReventlessInfra.StateChangeSlice.T
        with module Spec = Spec
    ) => StateChangeSlice_Builder.Make(Spec)
    /** Async variant — uses FIFO SQS channel, commands return `CommandPending`. */
    module MakeAsync = (Spec: Reventless.StateChangeSlice.Spec): (
      ReventlessInfra.StateChangeSlice.T with module Spec = Spec
    ) => {
      include StateChangeSlice_Builder.Make(Spec)
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

    // Accumulate fragments across independent plugin deployments: each plugin
    // writes its fragment to the Plugin RM table (keyed "deploy-schema:<name>")
    // at deploy time. The hook then scans for ALL deploy-schema entries and
    // stitches them together — ensuring the schema is cumulative rather than
    // overwritten by each plugin deployment.
    preResolversSchemaHook: (~name, pluginFragment) => {
      Console.log(`[preResolversSchemaHook] Pushing schema for plugin ${name} to AppSync`)

      // Capture deploy target synchronously — deployPlugin resets currentDeployTarget to
      // Domain after P.make() returns, before any Pulumi.Output async callbacks run.
      // All three values (capturedDeployTarget, schemaPrefix, targetApi) must be captured
      // here so the async Promise.then callback below uses the correct target.
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

      // Read Plugin RM table name from platform StackReference.
      let pluginRmTableNameOutput: Pulumi.Output.t<option<string>> = switch platformStackRef {
      | Some(stackRef) =>
        let direct: Pulumi.Output.t<option<JSON.t>> =
          stackRef->Pulumi.StackReference.getOutput("pluginRmTableName")
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
            ->Option.flatMap(d => d->Dict.get("pluginRmTableName"))
            ->Option.flatMap(v => v->JSON.Decode.string)
          }
        )
      | None => Pulumi.Output.make(None)
      }

      pluginRmTableNameOutput->Pulumi.Output.flatMap(tableNameOpt => {
        // Write this plugin's fragment to DynamoDB, then scan all deploy-schema
        // entries to collect every deployed plugin's fragment.
        let writeAndScanFragments = () =>
          switch tableNameOpt {
          | None =>
            Console.log(
              "[preResolversSchemaHook] No pluginRmTableName — skipping fragment persistence",
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
            Console.log(
              `[preResolversSchemaHook] Writing deploy-schema entry for ${name} to ${tableName}`,
            )
            PutCommand.send(PutCommand.make({PutCommand.tableName: tableName, item: deployItem}))
            ->Promise.then(_ => {
              // Scan for all deploy-schema entries from previously deployed plugins.
              Console.log(
                `[preResolversSchemaHook] Scanning ${tableName} for deploy-schema entries`,
              )
              ScanCommand.send(
                ScanCommand.make({
                  ScanCommand.tableName: tableName,
                  filterExpression: "begins_with(#id, :prefix)",
                  expressionAttributeNames: Dict.fromArray([("#id", "id")]),
                  expressionAttributeValues: Dict.fromArray([
                    (":prefix", schemaPrefix->JSON.Encode.string),
                  ]),
                }),
              )
            })
            ->Promise.then(result => {
              let items = result.items->Option.getOr([])
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
              Console.log(
                `[preResolversSchemaHook] Found ${fragments->Array.length->Int.toString} deploy-schema entries`,
              )
              Promise.resolve(fragments)
            })
            ->Promise.catch(err => {
              let msg =
                err
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("unknown")
              Console.log(
                `[preResolversSchemaHook] DynamoDB write/scan failed (${msg}) — using current plugin only`,
              )
              Promise.resolve([pluginFragment])
            })
          }

        targetApi->Pulumi.Output.flatMap(api =>
          api.id->Pulumi.Output.flatMap(apiId => {
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
              switch storedHash {
              | Some(prev) if prev == currentHash =>
                Console.log(
                  `[preResolversSchemaHook] SDL unchanged (hash ${currentHash->String.slice(~start=0, ~end=12)}…), skipping push`,
                )
              | _ =>
                Console.log(
                  `[preResolversSchemaHook] Pushing schema to API ${apiId} (${allPluginFragments->Array.length->Int.toString} plugin fragments, new hash: ${currentHash->String.slice(~start=0, ~end=12)}…)`,
                )
                let client = AppSync_Adapter.getClient()
                let _ = await client->AppSync_Adapter.startSchemaCreation({
                  apiId,
                  definition: sdl,
                })
                Console.log("[preResolversSchemaHook] startSchemaCreation called, waiting for ACTIVE")
                await AppSync_Adapter.waitForSchemaActive(client, apiId)
                Console.log("[preResolversSchemaHook] Schema is ACTIVE")
                switch tableNameOpt {
                | Some(tn) =>
                  await writeSchemaHash(~tableName=tn, ~apiId, ~hash=currentHash)
                | None => ()
                }
              }
            })
            ->Pulumi.Output.fromPromise
          })
        )
      })
    },
    // DCB EventLog created hook — extracts DynamoDB table name for DCB CommandTopic Lambda handler.
    onDcbEventLogCreated: dcbEventLogUnknown => {
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
    // Heartbeat EP channel hook — extracts SQS queue URL for heartbeat Lambda handler.
    onHeartbeatEpChannelAvailable: remoteChannelUnknown => {
      let remoteChannel = remoteChannelUnknown->asRemoteChannel
      switch remoteChannel.resources->Array.get(0) {
      | Some(resource) =>
        PluginRuntime_Builder.registerHeartbeatConfig(
          ~pluginId="",
          ~epQueueUrl=resource.id->Pulumi.Output.make,
          (),
        )
      | None =>
        Console.warn("Platform: heartbeat EP channel has no resources")
      }
    },

    // Phase 4 + 5: wire StateTopic and EventLogSubscription Lambdas per plugin.
    // Only active when the Events API resource exists (platform/monolithic mode).
    subscriptionInfraHook: ?domainEventsApiOpt->Option.map(eventsApi =>
      (params: ReventlessCore.Plugin_Helpers.subscriptionInfraParams) => {
        let {allQueryDbs, allEventTopics, eventLogEntries, opts} = params
        let customOpts =
          opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
        let graphqlApi = resolveHookedApi()

        // Phase 4: StateTopic per stream-enabled QueryDb
        allQueryDbs->Dict.forEachWithKey((_queryDbOutputs, readModelName) => {
          if QueryDbStorage_DynamoDbStream.streamRegistry->Set.has(readModelName) {
            let returnTypeName =
              ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry
              ->Dict.get(readModelName)
              ->Option.map(qn => qn.returnTypeName)
              ->Option.getOr(readModelName)
            StateTopic_AppSync.make(
              ~readModelName,
              ~topicName=returnTypeName,
              ~allQueryDbs,
              ~eventsApi,
              ~opts=customOpts,
            )
            // Source B subscription resolver — NONE data source required by AppSync UNIT resolvers
            let noneDs = PulumiAws.AppSync.DataSource.makeNoneDataSource(
              ~name=returnTypeName ++ "StateTopicNone",
              ~api=graphqlApi,
              ~opts=customOpts,
            )
            let _ = AppSync_Resolver_Retrying.makeSubscriptionResolver(
              ~name="on" ++ returnTypeName ++ "StateChanged",
              ~api=graphqlApi,
              ~field="on" ++ returnTypeName ++ "_stateChanged",
              ~dataSourceName=noneDs.name->Pulumi.Output.asInput,
              ~subscriptionFilter=`{filterGroup:[{filters:[{fieldName:"id",operator:"eq",value:ctx.args.id}]}]}`,
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
    DcbEventLogStorage.DynamoDb,
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
  // Use NoResolver variant — Plugin aggregate is internal (commands come via the
  // ExtensionPoint's publishToAggregates, not through AppSync mutations).
  module PluginAggregate: (
    ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
  ) = Aggregate_Builder_NoResolver.Make(
    ReventlessCore.PluginSpec,
    ReventlessCore.PluginBehavior,
    ReventlessInfra.NoEventMappings.Make(ReventlessCore.PluginSpec),
  )

  // Admin-internal Plugin read model — standalone component for the Plugin QueryDb
  // (DynamoDB table) that backs queryEngine.scan(~readModelName="Plugin", ...).
  module PluginReadModelMappings: Reventless.Projection.Mappings
    with module Target := ReventlessCore.PluginReadModelSpec = {
    // Reuse the already-instantiated Mappings from PluginProjection so the Mapping
    // module type is the same nominal type — no coercion needed.
    module M = ReventlessCore.PluginProjection.Mappings
    module type Mapping = M.Mapping
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = ReventlessCore.PluginProjection.mappings
  }

  // Use NoResolver variant — Plugin read model is internal (accessed via queryEngine,
  // not through AppSync GraphQL API). No AppSync resolvers needed.
  module PluginReadModel = ReadModel_Builder_NoResolver.Make(
    ReventlessCore.PluginReadModelSpec,
    PluginReadModelMappings,
  )

  // Admin-internal PlatformEventGraph read model — subscribes to Plugin aggregate events
  // and projects per-plugin component graphs (nodes + edges) into a QueryDb table.
  module PlatformEventGraphMappings: Reventless.Projection.Mappings
    with module Target := ReventlessCore.Platform_EventGraphReadModelSpec = {
    module M = ReventlessCore.Platform_EventGraphProjection.Mappings
    module type Mapping = M.Mapping
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = ReventlessCore.Platform_EventGraphProjection.mappings
  }

  module PlatformEventGraphReadModel = ReadModel_Builder_NoResolver.Make(
    ReventlessCore.Platform_EventGraphReadModelSpec,
    PlatformEventGraphMappings,
  )

  module type PluginMaker = {
    let make: unit => Plugin.component
  }

  let makeScheduler = () => {
    let component = Scheduler.make()
    component->ReventlessCore.Component.operations
  }

  type mcpSupported = | @as(true) McpSupported | @as(false) McpNotSupported
  let mcpSupported = McpNotSupported

  // In split mode, create a dedicated core AppSync API and push the core schema.
  // In unified mode, makePlatform is a no-op (schema stitching handled by events).
  let makePlatform = (~version, ~plugins: array<module(PluginMaker)>) => {
    Console.log(`[Platform] v${version}`)
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
    let _admin = Admin.construct(
      ~version,
      ~extensionPoints=[],
      ~aggregates=[module(PluginAggregate)],
      ~readModels=[module(PluginReadModel), module(PlatformEventGraphReadModel)],
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

    // Build each plugin.
    let pluginComponents = plugins->Array.map(plugin => {
      module P = unpack(plugin)
      P.make()
    })

    // Export first plugin's outputs (monolithic mode = typically single plugin).
    switch pluginComponents->Array.get(0) {
    | Some(pluginComponent) =>
      let pluginOutputs = pluginComponent->ReventlessCore.Component.outputs
      ReventlessCore.Plugin_Helpers.exportPluginOutputs(pluginOutputs)
    | None => ()
    }

    if Config.splitApi {
      // Split mode: push admin schema to the Platform (core) API.
      let adminBaseFragment = AppSync_Adapter.injectAwsAuthAll(
        ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
        ~group="Admin",
      )
      let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
        ~baseFragment=adminBaseFragment,
        ~pluginFragments=[],
      )
      let _ = platformApi->Pulumi.Output.flatMap(api =>
        api.id->Pulumi.Output.flatMap(apiId => {
          Console.log(`[makePlatform] Pushing admin schema to core-api ${apiId}`)
          let client = AppSync_Adapter.getClient()
          client
          ->AppSync_Adapter.startSchemaCreation({apiId, definition: sdl})
          ->Promise.then(async _ => {
            Console.log("[makePlatform] core-api startSchemaCreation called, waiting for ACTIVE")
            await AppSync_Adapter.waitForSchemaActive(client, apiId)
            Console.log("[makePlatform] core-api schema is ACTIVE")
          })
          ->Pulumi.Output.fromPromise
        })
      )

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

  let deployPlatform = (~version) => {
    Console.log(`[Platform:deployPlatform] v${version}`)
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
      let updateApiSchema = Some(async (queryEngine: Reventless.QueryEngine.operations) => {
        open Reventless.QueryEngine.Filter
        let apiId = domainApiId->Pulumi.Output.get
        let plugins = await queryEngine.scan(
          ~readModelName="Plugin",
          ~filterConfigs=[("status", Contains, String("Connected"))],
          ~limit=1000,
        )
        let fragments = plugins->Array.filterMap(json =>
          try {
            let state = json->S.parseOrThrow(ReventlessCore.PluginReadModelSpec.stateSchema)
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
        let _ = await AppSync_Adapter.getClient()->AppSync_Adapter.startSchemaCreation({
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
      ~readModels=[module(PluginReadModel), module(PlatformEventGraphReadModel)],
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

    // Extract admin aggregate/read-model data directly from admin outputs.
    // (Previously done via onAdminComponentsCreated hook — eliminated now that
    // Admin.construct() returns all needed data synchronously.)
    let publishToAggregatesQueueUrls = Dict.make()
    switch admin.aggregatesOutputs->Dict.get("Plugin") {
    | Some(pluginAgg) =>
      let queueUrl =
        pluginAgg.commandTopic->Pulumi.Output.flatMap(ct =>
          switch ct.resources->Array.get(0) {
          | Some(r) => r.id
          | None => Pulumi.Output.make("")
          }
        )
      publishToAggregatesQueueUrls->Dict.set("Plugin", queueUrl)
    | None => ()
    }
    // Extract Plugin RM table name as Output.t<string>.
    // IMPORTANT: Do NOT use option<Pulumi.Output.t<…>> — Pulumi Outputs use property
    // lifting, which breaks ReScript's internal option encoding (BS_PRIVATE_NESTED_SOME_NONE).
    // Instead, use Output.t<string> with a placeholder for "not available".
    let pluginReadModelTableName = switch admin.readModelsOutputs->Dict.get("Plugin") {
    | Some(pluginRm) =>
      switch pluginRm.queryDb.resources->Array.get(0) {
      | Some(r) => Some(r.name)
      | None => None
      }
    | None => None
    }
    PluginExtensionPointRuntime_Builder.registerPluginExtensionPoint(
      ~publishToAggregatesQueueUrls,
      ~pluginReadModelTableName?,
      (),
    )
    PluginRuntime_Builder.registerConfig(
      ~appSyncApiId=domainApiId,
      ~pluginReadModelTableName?,
      ~clonerEnabled=Config.cloner,
      (),
    )

    if Config.splitApi {
      // Split mode: push admin schema to the Platform (core) API.
      // Plugin API (domainApi) only gets plugin schema — no admin fields.
      // platformApi was created above before Admin.construct.
      let adminBaseFragment = AppSync_Adapter.injectAwsAuthAll(
        ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
        ~group="Admin",
      )
      let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
        ~baseFragment=adminBaseFragment,
        ~pluginFragments=[],
      )
      let _ = platformApi->Pulumi.Output.flatMap(api =>
        api.id->Pulumi.Output.flatMap(apiId => {
          Console.log(`[deployPlatform] Pushing admin schema to core-api ${apiId}`)
          let client = AppSync_Adapter.getClient()
          client
          ->AppSync_Adapter.startSchemaCreation({apiId, definition: sdl})
          ->Promise.then(async _ => {
            Console.log("[deployPlatform] core-api startSchemaCreation called, waiting for ACTIVE")
            await AppSync_Adapter.waitForSchemaActive(client, apiId)
            Console.log("[deployPlatform] core-api schema is ACTIVE")
          })
          ->Pulumi.Output.fromPromise
        })
      )

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
      // Unified mode: push admin schema to the shared API.
      // Plugin schema fragments are pushed at runtime via PluginExtensionPoint.
      let adminBaseFragment = AppSync_Adapter.injectAwsAuthAll(
        ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
        ~group="Admin",
      )
      let _ = AppSync_Adapter.updateSchema(
        ~api=domainApi,
        ~baseFragment=adminBaseFragment,
        ~pluginFragments=[],
      )

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
    switch ReventlessCore.Plugin_Helpers.onPlatformDeployedHook.contents {
    | Some(hook) =>
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
          let info: ReventlessCore.Plugin_Helpers.platformDeployedInfo = {
            name: Pulumi.Pulumi.getProjectName(),
            environment: Pulumi.Pulumi.getStackName(),
            region,
            domainApiEndpoint,
            domainApiRoleArn,
            platformApiEndpoint,
            platformApiRoleArn,
            adminResources,
          }
          hook(info)
        })
    | None => ()
    }
    Pulumi.Pulumi.getOutputs()
  }

  let startServers = () => ()

  let deployPlugin = (~version, ~plugin: module(PluginMaker), ~apiTarget=Domain) => {
    Console.log(`[Platform:deployPlugin] v${version}`)
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

    // Export interop metadata for cross-stack consumption.
    Pulumi.Pulumi.export("_interopMeta", ReventlessCore.Plugin_Helpers.getInteropMeta())

    // Export plugin outputs (plugin, tasks, eventMappers, extensionPoints) for cross-stack access.
    let pluginOutputs = pluginComponent->ReventlessCore.Component.outputs
    ReventlessCore.Plugin_Helpers.exportPluginOutputs(pluginOutputs)

    Pulumi.Pulumi.getOutputs()
  }
}

// Default platform — split API, no cloner.
module Make = (): (
  ReventlessInfra.Platform.T with type api = Types.AppSync.api and type role = Types.AppSync.role
) => {
  include MakeWithConfig({
    let splitApi = true
    let cloner = false
  })
}
