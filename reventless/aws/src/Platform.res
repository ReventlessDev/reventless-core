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

// Object stores provisioned from field declarations — populated by
// deployPlatform. Access via getObjectStoreEndpoints() after it has been called.
//
// A platform whose UI ships from its own stack needs each store's presign
// endpoint, and `deployPlatform` is the only place that knows it. Without this
// the store is provisioned and unnameable: the stores are built unconditionally,
// but every consumer of them used to sit inside `switch hostUiBundle`. Same
// reason `getSplitApiOutputs` exists — a root cannot re-export what it cannot
// reach.
type objectStoreEndpoint = {
  // The store's qualified `{plugin}.{store}` name. The same string
  // `pluginStructure.requiredStores` carries, so a UI's binding key and the
  // declaration's identity are one value rather than two that can drift.
  store: string,
  // The path this store's keys are rooted at, and therefore the path it must be
  // served under for a minted `/{key}` ref to resolve.
  keyPrefix: string,
  // The bucket's **physical** name, which is not the name the layout computes:
  // Pulumi auto-names the resource, so a `SharedBucket` stack asking for
  // `alpha-stores` gets `alpha-stores-507202d`. An Output because that suffix is
  // only known after the bucket resolves — and a plain string here is exactly
  // how this shipped exporting a bucket name that no ARN matches.
  bucketName: Pulumi.Output.t<string>,
  // Public base URL the store is served from, when the platform serves it
  // itself. `None` when a host-UI bundle is deployed — there the shell's own
  // origin serves the store same-origin and a relative `/{prefix}/…` resolves
  // without a base.
  baseUrl: option<Pulumi.Output.t<string>>,
}
let objectStoreEndpointsRef: ref<array<objectStoreEndpoint>> = ref([])

/** Returns the object stores this platform provisioned from field declarations.

    Empty when nothing is declared — a legitimate answer rather than a
    call-order mistake, so this returns `[]` instead of throwing the way
    `getApiConfig` does. */
let getObjectStoreEndpoints = () => objectStoreEndpointsRef.contents

/** The geocoding place index this platform provisioned, for the monolithic case.

    In plugin mode the value crosses to the plugin stack as the `geocoderPlaceIndex`
    export; when platform and plugin are one program there is no stack to read, so
    `deployPlatform` records it here and `deployPlugin` picks it up — the same two
    halves `objectStoreEndpointsRef` exists for. Slice Lambdas call Amazon Location
    directly with this index name; the browser reaches the same capability through
    the platform API's `Query.geocode` resolver (D9 half 2), so there is no endpoint
    to carry beside it.

    A plain Output with `""` as the "no geocoder" sentinel, never
    `option<Pulumi.Output.t<_>>`: any generic `Option.*` over an Output runs
    `valFromOption`, whose nested-option probe hits the Output proxy — where every
    property access returns a truthy Output — and corrupts it. Same reasoning, and
    the same sentinel, as `PluginRuntime_Builder.inboundSliceReg.auditTableName`. */
let geocoderPlaceIndexRef: ref<Pulumi.Output.t<string>> = ref(Pulumi.Output.make(""))

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
    // The UiFragments StateViewSlice table is scanned by the Platform_UIFragments
    // Lambda (DynamoDB scan) — keep it off the Postgres selection like the other
    // admin stores.
    QueryDbBackend.exempt(ReventlessCore.UiFragments.name)
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

  // The declared object stores, as the upload claimer needs them: qualified
  // name, physical bucket, served prefix.
  //
  // Stores are provisioned by the *platform* deploy; the claimer is wired into
  // the *plugin* stack, because that is where the event log streams it reads
  // exist. So the two halves meet here — across the stack reference in plugin
  // mode, and through the platform's own in-process record when platform and
  // plugin are one program.
  //
  // Read lazily (a thunk, not a value) for the monolithic case: `deployPlatform`
  // fills `objectStoreEndpointsRef` as it provisions, and this is called during
  // a later plugin build.
  let claimStores = (): Pulumi.Output.t<array<Upload_Claim_S3.storeConfig>> =>
    switch platformStackRef {
    | Some(stackRef) =>
      // The `objectStores` export: `{ "<plugin>.<store>": {bucketName, keyPrefix} }`.
      // A platform that provisions none omits the export entirely, which reads
      // as "no store to claim in" — the claimer then builds nothing, rather
      // than building something that can reach nothing.
      (stackRef->Pulumi.StackReference.getOutput("objectStores"): Pulumi.Output.t<option<JSON.t>>)
      ->Pulumi.Output.apply(objectStores =>
        objectStores
        ->Option.flatMap(JSON.Decode.object)
        ->Option.getOr(Dict.make())
        ->Dict.toArray
        ->Array.filterMap(((qualified, v)) =>
          v
          ->JSON.Decode.object
          ->Option.flatMap(o =>
            switch (
              o->Dict.get("bucketName")->Option.flatMap(JSON.Decode.string),
              o->Dict.get("keyPrefix")->Option.flatMap(JSON.Decode.string),
            ) {
            | (Some(bucketName), Some(servedPrefix)) =>
              Some({Upload_Claim_S3.qualified: qualified, bucketName, servedPrefix})
            | _ => None
            }
          )
        )
      )
    | None =>
      objectStoreEndpointsRef.contents
      ->Array.map(e =>
        e.bucketName->Pulumi.Output.apply(bucketName => {
          Upload_Claim_S3.qualified: e.store,
          bucketName,
          servedPrefix: e.keyPrefix,
        })
      )
      ->Pulumi.Output.all
    }

  // ── Merged-mode source SDL assembly (merged-api plan, Phase 3) ────────────
  // Empty base fragment — no types, no mutations, no queries. Used by the
  // plugin Api in split mode (so plugin schema has no core fields) and as the
  // base of the split-mode Domain source document below.
  // Split-mode Domain base fragment. No component fields — the Domain merged
  // API's fields come from plugin sources; this document only anchors the
  // canonical relay base types. `Platform_ping` exists because a GraphQL
  // schema cannot have an empty Query type (unresolved → null; spike
  // precedent). The global `node` query is NOT emitted on AWS — see the
  // "Relay node resolution" section of the merged-api plan (never resolved on
  // any deployed AWS platform, zero consumers; the Node interface and global
  // IDs stay).
  // The upload service (route B) lives on the domain base, not the Admin-gated admin
  // base: `Upload_Presign`/`Upload_Release` take the domain API's default
  // `AllowAuthenticated` auth so any authenticated user can mint/release their own
  // uploads. See [docs/plans/done/upload-release-path.md] § "Which API". (Split mode only —
  // unified mode carries the admin base here instead; it declares no stores in practice,
  // so the upload resolvers below are never created there.)
  let domainBaseFragment = ReventlessCore.GraphQL_Stitcher.encode({
    types: Array.concat(
      ReventlessCore.Platform_AdminApi.uploadTypes,
      ReventlessCore.Platform_AdminApi.geocodeTypes,
    ),
    mutations: ReventlessCore.Platform_AdminApi.uploadMutationFields,
    queries: Array.concat(
      ["  Platform_ping: String"],
      ReventlessCore.Platform_AdminApi.geocodeQueryFields,
    ),
    subscriptions: [],
    subscriptionSources: [],
  })

  // The canonical base document for a merged API's platform-owned source:
  // rendered standalone (relay base types included, no global `node` query),
  // AWS-dialect decorated, and `@canonical`-stamped so the platform-owned
  // shared types win over every plugin source's standalone copy (divergence
  // is shadowed, not MERGE_FAILED — Phase-0 finding 1).
  let assembleCanonicalSourceSdl = (~baseFragment): string =>
    AppSync_Adapter.stitchStandaloneWithAwsDirectives(~fragment=baseFragment)
    ->AppSync_SdlDecorate.stampCanonicalTypes

  // Admin base as a source-API document — auth-decorated (all fields Admin,
  // Cognito-only; the deploy-time SigV4 system-caller fields died with the
  // fragment registry) plus the canonical stamp.
  let adminSourceSdl = (): string =>
    assembleCanonicalSourceSdl(
      ~baseFragment=AppSync_Adapter.injectAwsAuthAll(
        ReventlessCore.Platform_AdminApi.baseFragment(~cloner=Config.cloner),
        ~group="Admin",
      ),
    )

  // Split-mode Domain source document: relay base types + Platform_ping — the
  // Domain merged API's canonical owner (plugin fields come from plugin sources).
  let domainBaseSourceSdl = (): string => assembleCanonicalSourceSdl(~baseFragment=domainBaseFragment)

  let (domainApi, domainApiRole, platformApi, platformApiRole) = switch platformStackRef {
  | None =>
    // The Domain API is an ordinary GRAPHQL source API with a DECLARATIVE
    // schema. Unified: it carries the admin base (the canonical document).
    // Split: it carries only the relay base document; the admin base lives on
    // the Platform source API created in deployPlatform.
    let schema = if Config.splitApi {
      domainBaseSourceSdl()
    } else {
      adminSourceSdl()
    }
    let (api, role) = AppSync_Adapter.makeSourceApiResource(~name="DomainApi", ~schema, ~opts={})
    // In platform/monolithic mode the platform API is not yet known — it is created
    // during deployPlatform/makePlatform and the ref is updated there.
    (api, role, api, role)
  | Some(stackRef) =>
    // Plugin mode (merged-api plan, Phase 4): the plugin stack owns a real
    // SOURCE API — the single writer for its subgraph schema and resolvers.
    // It fills all four API slots (resolver wiring is target-agnostic here;
    // apiTarget only decides WHICH merged API the association in deployPlugin
    // points at). The user pool comes from the platform's exports so Cognito
    // primary auth matches across all sources of the merged endpoint — the
    // plugin stack provisions no pool/client.
    //
    // In ESM mode, Pulumi exports are inside the "default" output.
    // Try top-level field first (CJS), fall back to "default".<field> (ESM).
    let defaultOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput("default")
    let cognitoPoolIdOutput: Pulumi.Output.t<option<string>> =
      stackRef->Pulumi.StackReference.getOutput("cognitoUserPoolId")
    let cognitoRegionOutput: Pulumi.Output.t<option<string>> =
      stackRef->Pulumi.StackReference.getOutput("cognitoRegion")
    let userPoolConfig =
      (cognitoPoolIdOutput, cognitoRegionOutput, defaultOutput)
      ->Pulumi.Output.all3
      ->Pulumi.Output.apply(((directPoolId, directRegion, default)) => {
        let getFromDefault = key =>
          default
          ->Option.flatMap(d => d->JSON.Decode.object)
          ->Option.flatMap(d => d->Dict.get(key))
          ->Option.flatMap(v => v->JSON.Decode.string)
        let userPoolId =
          directPoolId
          ->Option.orElse(getFromDefault("cognitoUserPoolId"))
          ->Option.getOrThrow(
            ~message="Platform stack does not export 'cognitoUserPoolId' — redeploy the platform stack first",
          )
        let awsRegion = directRegion->Option.orElse(getFromDefault("cognitoRegion"))
        (
          {
            userPoolId,
            ?awsRegion,
            defaultAction: PulumiAws.AppSync.GraphQLApi.ALLOW,
          }: PulumiAws.AppSync.GraphQLApi.userPoolConfig
        )
      })
    let (api, role) = AppSync_Adapter.makePluginSourceApiResource(
      ~name="PluginSourceApi",
      ~userPoolConfig,
      ~opts={},
    )
    (api, role, api, role)
  }

  // Expose api/apiRole as Platform.T value bindings so DCB slice builders
  // can access them through the platform interface.
  let api = domainApi
  let apiRole = domainApiRole

  // Populate apiConfig with both domain and platform API references.
  // In platform/monolithic mode, platformApi starts as domainApi and is updated
  // by deployPlatform/makePlatform once the platform API resource is created (split mode).
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

  // Admin UI-fragment registry slices (docs/plans/event-sourced-fragment-registries.md): the
  // platform UI-fragment registry hosted as admin DCB slices sharing the admin DcbEventLog.
  // Built once at platform-module level and passed into Admin.construct below (registers the
  // slice's command handler exactly once).
  module UiFragmentRegistrySlice = StateChangeSlice.Make(
    ReventlessCore.UiFragmentRegistry,
    ReventlessCore.UiFragmentRegistry_Behavior,
  )
  module UiFragmentsViewSlice = StateViewSlice.Make(
    ReventlessCore.UiFragments,
    ReventlessCore.UiFragments_Projection,
  )
  // (domainBaseFragment — the split-mode Domain source base — is defined above,
  // next to the merged-mode source SDL assembly that uses it.)

  // ── Typed identity casts — see Platform_Casts.res for rationale ─────────
  open Platform_Casts

  // AWS platform hooks — all AWS-specific callbacks defined as a record.
  // In-memory hooks (mutationResolverHook etc.) are absent (optional = None).
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
  // Admin DCB mutation resolvers bind here (the Platform API in split mode). Set by
  // makePlatform / deployPlatform once the Platform API resource exists. Distinct from hooksApiRef
  // because both are read in *deferred* callbacks — admin resolvers need the Platform API while the
  // plugins built afterwards read hooksApiRef (Domain/deploy-target). See platformHooks.adminApi.
  let hooksAdminApiRef: ref<option<ReventlessCore.Plugin_Helpers.hookedValue<unknown>>> = ref(None)

  // Merged mode (plugin stack): the subgraph schema-push Output produced by
  // preResolversSchemaHook, captured so deployPlugin can sequence the
  // SourceApiAssociation behind it (the association's initial merge needs the
  // source schema to exist on the plugin's source API).
  let mergedSchemaPushedRef: ref<option<Pulumi.Output.t<unit>>> = ref(None)

  let resolveHookedApi = (): Types.AppSync.api =>
    switch hooksApiRef.contents {
    | Some({val}) => Obj.magic(val)
    | None => resolveTargetApi()
    }

  // Admin DCB resolvers resolve to the Platform API when it has been recorded; otherwise fall back
  // to the same api plugins use (unified mode, or before the split Platform API exists).
  let resolveAdminHookedApi = (): Types.AppSync.api =>
    switch hooksAdminApiRef.contents {
    | Some({val}) => Obj.magic(val)
    | None => resolveHookedApi()
    }


  let hooks: ReventlessCore.Plugin_Helpers.platformHooks = {
    // AWS uses Interstack for admin extension points — leave ref at empty dict.
    adminExtensionPoints: ref(Pulumi.Output.make(Dict.make())),
    // Platform context — populated by makePlatform/deployPlugin before plugin build.
    scheduler: ref(None),
    schedulerRoleUrn: ref(Pulumi.Output.make("")),
    api: hooksApiRef,
    apiRole: hooksApiRoleRef,
    adminApi: hooksAdminApiRef,
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
    dcbAppSyncResolverHook: ({runtime, fieldNames, tags, onAdminApi, opts}) => {
      let runtimeTyped: ReventlessCore.Runtime.environment<Util.Lambda.runtimeParts> =
        runtime->asLambdaRuntime
      CommandGeneratorResolvers_AppSync.makeDcb(
        // Admin slices bind on the Platform API (split mode); plugins on the deploy-target api.
        ~api=onAdminApi ? resolveAdminHookedApi() : resolveHookedApi(),
        ~runtime=runtimeTyped,
        ~fieldNames,
        ~tags,
        ~onAdminApi,
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
    // Admin base SDL is DECLARATIVE on the source API resource
    // (makeSourceApiResource) — the provider runs StartSchemaCreation + poll
    // before the resource resolves, so admin resolvers chained on the API are
    // already ordered after the schema is ACTIVE. No push.
    preAdminResolversSchemaHook: (~adminBarrier) => adminBarrier,

    // Push the plugin's standalone subgraph document to the plugin's OWN
    // source API — a single writer by construction. The returned Output gates
    // resolver creation and deployPlugin additionally sequences the
    // SourceApiAssociation behind it (the initial merge needs the source
    // schema present). Under AUTO_MERGE every later schema update here
    // re-merges automatically.
    preResolversSchemaHook: (~name, ~version, pluginFragment) => {
      let sdl = AppSync_Adapter.stitchStandaloneWithAwsDirectives(~fragment=pluginFragment)
      let pushed =
        domainApi->Pulumi.Output.flatMap(api =>
          api.id->Pulumi.Output.flatMap(apiId => {
            log.info(
              ~comp="preResolversSchemaHook",
              `Pushing subgraph schema for ${name}@${version} to source API ${apiId}`,
            )
            let client = AppSync_Adapter.getClient()
            client
            ->AppSync_Adapter.startSchemaCreationRetrying({apiId, definition: sdl})
            ->Promise.then(async _ => {
              await AppSync_Adapter.waitForSchemaActive(client, apiId)
              log.info(~comp="preResolversSchemaHook", "subgraph schema is ACTIVE")
            })
            ->Pulumi.Output.fromPromise
          })
        )
      mergedSchemaPushedRef := Some(pushed)
      pushed
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
    // DCB CommandTopic created hook — extracts SQS queue URL for slice builders,
    // and the queue resource so the slice Lambda's role is granted
    // `sqs:SendMessage` on it.
    onDcbCommandTopicCreated: dcbCommandTopicUnknown => {
      let commandTopic = dcbCommandTopicUnknown->asDcbCommandTopicComponent
      let channel = commandTopic->ReventlessCore.CommandTopic_Adapter.channel
      let channelParts = channel.parts->asSqsChannelParts
      AutomationSliceRuntime_Builder_Single.setDcbQueueUrl(
        ~resource=?channel.resources->Array.get(0),
        channelParts.queue.id,
      )
    },
    // DCB slices created hook — finalize slice Lambdas.
    onDcbSlicesCreated: dcbEventLogUnknown => {
      let dcbEventLog = dcbEventLogUnknown->asDcbEventLog
      StateViewSliceRuntime_Builder_Single.finishWithDcbEventLog(dcbEventLog)
      AutomationSliceRuntime_Builder_Single.finishWithDcbEventLog(dcbEventLog)
    },
    // Heartbeat EP channel hook — extracts SQS queue URL for heartbeat Lambda handler
    // and records the calling plugin's id so the Lambda runtime can emit Connect commands
    // with a non-empty SQS MessageGroupId (FIFO requirement).
    onHeartbeatEpChannelAvailable: (remoteChannelUnknown, ~pluginId, ~heartbeatInterval) => {
      let remoteChannel = remoteChannelUnknown->asRemoteChannel
      switch remoteChannel.resources->Array.get(0) {
      | Some(resource) =>
        PluginRuntime_Builder.registerHeartbeatConfig(
          ~pluginId,
          ~heartbeatTimeout=heartbeatInterval,
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
        let {pluginName, allQueryDbs, allEventTopics, eventLogEntries, opts} = params
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
          let topicOutputs =
            allEventTopics
            ->Dict.get(entry.displayName)
            ->Option.orElse(allEventTopics->Dict.get(entry.busKey))
          isSns
            ? topicOutputs->Option.forEach(outputs =>
                EventLogSubscription_AppSync.make(
                  ~name=entry.displayName,
                  ~topicName=entry.displayName,
                  ~eventTopicOutputs=outputs,
                  ~eventsApi,
                  ~opts=customOpts,
                )
              )
            : ()
          // Register this event log with the upload claimer if — and only if —
          // its events declare a `@storageRef` field. An event log that declares
          // none is not registered, so a platform whose plugins declare no store
          // provisions no claimer at all. `isSns` is the same synchronous answer
          // the subscription above turns on, so the two cannot disagree about
          // which channel an event log publishes through.
          topicOutputs->Option.forEach(outputs =>
            Upload_Claim_S3.make(
              ~plugin=pluginName,
              ~eventLogName=entry.displayName,
              ~eventSchema=entry.eventSchema,
              ~eventTopicOutputs=outputs,
              ~isStreamBacked=!isSns,
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
        // Same timing constraint, same reason: the claimer's registry is filled
        // by the loop just above and drained here.
        Upload_Claim_S3.finish(~plugin=pluginName, ~stores=claimStores, ~opts=customOpts)
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
  // from Platform_AdminApi.queryEntries before this builder runs.
  module PluginReadModel = ReadModel_Builder_Single_Stream.Make(
    ReventlessCore.PluginsReadModelSpec,
    PluginReadModelMappings,
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

  // In split mode, create a dedicated platform AppSync API and push the platform schema.
  // In unified mode, makePlatform is a no-op (schema stitching handled by events).
  let makePlatform = (~version, ~plugins: array<module(PluginMaker)>) => {
    log.info(~comp="Platform", `v${version}`)
    let _ = plugins
    // Retired with the merged-API cutover: on AWS the platform deploys with
    // deployPlatform (staged) and each plugin with deployPlugin — makePlatform
    // predates the merge path and never gained merged wiring.
    failwith(
      "makePlatform is not supported on AWS — deploy the platform with deployPlatform and " ++
      "each plugin with deployPlugin (merged-API composition).",
    )
  }

  // Optional host UI shell bundle: a static SPA (e.g. reventless-ui's host-shell)
  // hosted on the platform's CloudFront-fronted S3 bucket. The platform writes a
  // `config.json` next to `index.html` so the shell discovers `apiEndpoint` and
  // `region` at boot without rebuild.
  type hostUiBundleConfig = {
    // Directory holding the built shell bundle. Defaults to the resolved
    // `@reventlessdev/reventless-host-shell` dist — the line every platform
    // root used to repeat verbatim. Set it only to host a different bundle.
    assetsDir?: string,
    // Defaults to the `~version` passed to `deployPlatform`.
    bundleVersion?: string,
    // Optional path to a static AutoUI `ui-hints.json` (assistant-authored,
    // plain data — no app rebuild). When set, the deploy reads it and writes it
    // verbatim as a `ui-hints.json` BucketObject beside `config.json`, so the
    // shell's static-hints path works in a deployed app. Unset ⇒ no file
    // written; the shell treats the resulting 404 as "no hints" and boots
    // unchanged. Single-mode shape: one origin-relative file per deployment.
    uiHintsFile?: string,
    // Optional geocoding place index, as returned by
    // `Capability_Geocoding_AwsLocation.make`. When set, the deploy provisions the
    // capability's client door — a Cognito-authenticated `Query.geocode` resolver
    // on the domain API (`Geocoder_AwsLocation_Resolver`, split mode) — and exports
    // the index name for the unattended slice path. Unset ⇒ no resolver, no export.
    geocoderPlaceIndex?: ReventlessInfra.Platform.geocoderIndex,
    // Optional object store for direct-to-S3 uploads, as returned by
    // `Capability_ObjectStore_S3.make`. When set, the deploy registers it with
    // the platform's one Upload service (`Upload_Presign_S3`) under the `uploads`
    // store key, and fronts the store read-only on the host-shell CloudFront
    // distribution under that prefix (a `{prefix}/*` ordered cache behavior +
    // origin + scoped BucketPolicy, private, OAC-read).
    //
    // No endpoint is written into config.json: under route B a caller mints
    // through the domain API's `Upload_Presign` mutation, naming the store, so
    // there is no per-store URL to publish or to resolve.
    //
    // One field replaces the former `enableUploads` / `uploadBucketName` /
    // `servedBuckets` trio, which were three ways of saying one thing and left
    // the prefix to be restated by hand on the serve side. The framework now
    // writes the prefix once and consumes it on both sides, so a mismatch is
    // unrepresentable rather than merely discouraged.
    uploadBucket?: ReventlessInfra.Platform.objectStore,
    // Optional view modes the deployed shell loads at boot. Written to
    // config.json as `viewModes`, with each mode's options flattened beside it
    // (`Map({style})` ⇒ `"viewModes": ["map"], "mapStyle": …`). Unset ⇒ both
    // keys omitted and the shell loads no optional mode, so a non-map
    // deployment still downloads no maplibre chunk and gets a byte-identical
    // config.json.
    //
    // This is the one input that decides what the shell *does* rather than what
    // it points at, and it is load-bearing twice over: naming `Map` is what
    // makes both the map view and the map-backed geo-point command input exist,
    // and it is what makes a provisioned `geocoderPlaceIndex` reachable at all
    // (the geocoder client is built inside the map chunk).
    viewModes?: array<ReventlessInfra.Platform.viewMode>,
    // Shell-owned config.json keys the framework has no opinion about
    // (`accessTiers`, `platformName`, `assetOrigins`, `uiHintsUrl`, …), merged
    // in verbatim under the computed keys. Untyped on purpose — re-declaring
    // the shell's schema here would cost a lockstep core release per UI knob.
    // A key that collides with a computed one fails the deploy naming it.
    shellConfig?: dict<JSON.t>,
  }

  // Merged-mode outputs of deployPlatform — the merged API(s), plus the
  // deploy-time merge gates (Outputs that resolve on MERGE_SUCCESS and fail
  // the deploy on MERGE_FAILED; folded into the ARN exports so they are
  // consumed). platformMerged == domainMerged in unified mode, mirroring the
  // platformApi/domainApi convention.
  type mergedApiOutputs = {
    domainMerged: AppSync_MergedApi.t,
    platformMerged: AppSync_MergedApi.t,
    domainMergeGate: Pulumi.Output.t<unit>,
    platformMergeGate: Pulumi.Output.t<unit>,
  }

  let deployPlatform = (
    ~version,
    ~hostUiBundle: option<hostUiBundleConfig>=?,
    ~capabilities: array<ReventlessInfra.Platform.capability>=[],
  ) => {
    log.info(~comp="Platform:deployPlatform", `v${version}`)
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some(domainApi->wrapHookedValue)
    hooks.apiRole := Some(domainApiRole->wrapHookedValue)

    // Phase 2: create the Platform API resource early — before Admin.construct —
    // so admin resolvers are attached to the correct API in split mode.
    // In unified mode this is the same resource as the Domain API.
    // On the merge path the Platform API is an ordinary GRAPHQL source API
    // carrying the admin canonical document declaratively.
    let (platformApi, platformApiRole) = if Config.splitApi {
      AppSync_Adapter.makeSourceApiResource(~name="PlatformApi", ~schema=adminSourceSdl(), ~opts={})
    } else {
      (domainApi, domainApiRole)
    }

    // ── Merged-API composition (merged-api plan, Phase 3) ──────────────────
    // Create the merged API(s) and associate the platform-owned source(s).
    // Plugin stacks associate their own source APIs against the exported
    // merged-API ARN (Phase 4); `pulumi destroy` of a plugin stack deletes
    // its association — retirement by construction.
    let mergedOutputs = {
      AppSync_MergedApi.assertCompatiblePrimaryAuth(
        ~sourceMode=AppSync_MergedApi.authenticationTypeName(
          AppSync_Adapter.primaryAuthenticationType,
        ),
        ~mergedMode=AppSync_MergedApi.primaryAuthMode,
      )
      let domainMerged = AppSync_MergedApi.make(~name="DomainMergedApi", ~opts={})
      if Config.splitApi {
        // Split: admin source → Platform merged API; the relay-base Domain
        // source (the Domain merged API's canonical owner) → Domain merged.
        let platformMerged = AppSync_MergedApi.make(~name="PlatformMergedApi", ~opts={})
        let platformAssoc = AppSync_MergedApi.associateSource(
          ~name="PlatformAdminSourceAssociation",
          ~mergedApi=platformMerged,
          ~sourceApi=platformApi,
          ~opts={},
        )
        let domainAssoc = AppSync_MergedApi.associateSource(
          ~name="DomainBaseSourceAssociation",
          ~mergedApi=domainMerged,
          ~sourceApi=domainApi,
          ~opts={},
        )
        Some({
          domainMerged,
          platformMerged,
          domainMergeGate: AppSync_MergedApi.mergeStatusGate(
            ~mergedApi=domainMerged,
            ~association=domainAssoc,
          ),
          platformMergeGate: AppSync_MergedApi.mergeStatusGate(
            ~mergedApi=platformMerged,
            ~association=platformAssoc,
          ),
        })
      } else {
        // Unified: the single source API carries the admin canonical document.
        let assoc = AppSync_MergedApi.associateSource(
          ~name="DomainAdminSourceAssociation",
          ~mergedApi=domainMerged,
          ~sourceApi=domainApi,
          ~opts={},
        )
        let gate = AppSync_MergedApi.mergeStatusGate(~mergedApi=domainMerged, ~association=assoc)
        Some({
          domainMerged,
          platformMerged: domainMerged,
          domainMergeGate: gate,
          platformMergeGate: gate,
        })
      }
    }

    // Admin DCB mutation resolvers bind to the Platform API (split mode) or the shared api
    // (unified). Recorded now that the Platform API resource exists, so the admin's deferred
    // dcbConnectFn (via ~onAdminApi) targets it rather than the Domain/deploy-target hooksApiRef.
    hooks.adminApi := Some(platformApi->wrapHookedValue)

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
      // AdminEventCollector Lambda (EventCollectorEntryPoint.mjs), not in
      // this deploy-time EP Lambda — which only handles incoming commands
      // (Heartbeat, ForwardCommand). None here keeps the deploy-time path
      // unchanged; the .mjs entry point supplies a real implementation.
      let manageSubscriptions = None
      // No runtime schema writer exists under merged-API composition — every
      // source API is its own single writer.
      let updateApiSchema = None
    })

    // Phase 2: Admin resolvers go on the Platform API (platformApi) in split mode,
    // on the shared Domain API in unified mode.
    let admin = Admin.construct(
      ~version,
      ~extensionPoints=[module(PluginExtensionPoint)],
      ~aggregates=[module(PluginAggregate)],
      ~readModels=[module(PluginReadModel)],
      ~scheduler,
      ~resourceNaming=Util_ResourceNaming.operations,
      ~api=platformApi,
      ~apiRole=platformApiRole,
      ~stateChangeSlices=[module(UiFragmentRegistrySlice)],
      ~stateViewSlices=[module(UiFragmentsViewSlice)],
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
      ~schedulerRoleArn=hooks.schedulerRoleUrn.contents,
      ~clonerEnabled=Config.cloner,
      (),
    )

    // ── Content-addressed offload bucket (@offload primitive) ─────────────────
    //
    // One platform-level bucket holds the large `pluginDefinition` fields
    // (`structure` ~74 KB, `apiSchemaFragment` ~32 KB) keyed by their SHA-256
    // (`sha256/<hash>`). Content-addressed and immutable, so it needs no CORS,
    // lifecycle, or versioning — identical payloads across versions land on one
    // object (free dedupe). Plugin stacks PUT to it (a `BucketObject` in the
    // plugin deploy, via the offload hook) and the ComponentDefinitions Lambda
    // GETs from it to resolve an offloaded `structure`. Kept out of the declared
    // `@storageRef` stores and their pending-claim/expiry machinery: offload
    // objects are written durably up front and are never "pending".
    let offloadProtection = Util_StoreLayout.protectionFor(~stack=Pulumi.Pulumi.getStackName())
    let offloadBucket = PulumiAws.S3.Bucket.make(
      ~name="reventless-offload",
      ~args={
        forceDestroy: (offloadProtection == Unprotected)->Pulumi.Input.make,
        tags: AWS.Tags.make(
          ~name="reventless-offload",
          ~kind=ReventlessCore.ComponentType.Platform,
          ~role=Other("Offload"),
          ~scope=Platform,
        ),
      },
      ~opts={protect: offloadProtection == Protected},
    )
    let offloadBucketName = offloadBucket.bucket
    let _offloadPab = PulumiAws.S3.BucketPublicAccessBlock.make(
      ~name="reventless-offload-pab",
      ~args={
        bucket: offloadBucket.id->Pulumi.Output.asInput,
        blockPublicAcls: Pulumi.Input.make(true),
        blockPublicPolicy: Pulumi.Input.make(true),
        ignorePublicAcls: Pulumi.Input.make(true),
        restrictPublicBuckets: Pulumi.Input.make(true),
      },
    )
    Pulumi.Pulumi.export("offloadBucket", offloadBucketName)

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
        ~offloadBucketName,
        ~schemaReady=admin.adminSchemaPushed,
        ~opts={},
      )
    | None => ()
    }

    // Mount the Platform_UIFragments Lambda resolver — scans the UiFragments
    // StateViewSlice table provisioned above and returns one entry per registered
    // plugin UI.
    switch admin.stateViewSlicesOutputs->Dict.get("UiFragments") {
    | Some(rm) =>
      switch rm.queryDb.resources->Array.get(0) {
      | Some(r) =>
        Platform_UIFragments_Lambda.make(
          ~api=platformApi,
          ~uiFragmentRegistryTableName=r.name,
          ~schemaReady=admin.adminSchemaPushed,
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

    // Merged-API exports — plugin stacks associate their source APIs against
    // these ARNs (this replaces the SigV4 RegisterApiFragment handshake as the
    // cross-stack wiring on the merge path), and `mergedApiPrimaryAuth` is the
    // primary-auth contract source APIs must match. The ARN exports are gated
    // on the merge-status poll so a MERGE_FAILED fails the deploy loudly
    // instead of silently serving the last-good merged schema.
    switch mergedOutputs {
    | Some({domainMerged, platformMerged, domainMergeGate, platformMergeGate}) =>
      let mergeGatedArn = (merged: AppSync_MergedApi.t, gate: Pulumi.Output.t<unit>) =>
        (
          merged.api->Pulumi.Output.flatMap((api: PulumiAws.AppSync.GraphQLApi.t) => api.arn),
          gate,
        )
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((arn, _)) => arn)
      let mergedEndpoint = (merged: AppSync_MergedApi.t) =>
        merged.api->Pulumi.Output.flatMap((api: PulumiAws.AppSync.GraphQLApi.t) =>
          api.uris->Pulumi.Output.apply(uris => uris.graphQL)
        )
      Pulumi.Pulumi.export("domainMergedApiArn", mergeGatedArn(domainMerged, domainMergeGate))
      Pulumi.Pulumi.export(
        "domainMergedApiId",
        domainMerged.api->Pulumi.Output.flatMap((api: PulumiAws.AppSync.GraphQLApi.t) => api.id),
      )
      Pulumi.Pulumi.export("domainMergedApiEndpoint", mergedEndpoint(domainMerged))
      Pulumi.Pulumi.export("platformMergedApiArn", mergeGatedArn(platformMerged, platformMergeGate))
      Pulumi.Pulumi.export(
        "platformMergedApiId",
        platformMerged.api->Pulumi.Output.flatMap((api: PulumiAws.AppSync.GraphQLApi.t) => api.id),
      )
      Pulumi.Pulumi.export("platformMergedApiEndpoint", mergedEndpoint(platformMerged))
      Pulumi.Pulumi.export(
        "mergedApiPrimaryAuth",
        Pulumi.Output.make(AppSync_MergedApi.primaryAuthMode),
      )
    | None => ()
    }

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
    // Client-facing endpoints: on the merge path clients query the MERGED
    // endpoints (the source-API endpoints stay exported for coexisting
    // push-path stacks) — these also feed the host-UI config.json below.
    let clientDomainApi = switch mergedOutputs {
    | Some({domainMerged}) => domainMerged.api
    | None => domainApi
    }
    let clientPlatformApi = switch mergedOutputs {
    | Some({platformMerged}) => platformMerged.api
    | None => platformApi
    }
    let resolvedDomainApiEndpoint = clientDomainApi->Pulumi.Output.flatMap(api =>
      api.uris->Pulumi.Output.apply(uris => uris.graphQL)
    )
    let resolvedDomainApiRoleArn = domainApiRole->Pulumi.Output.flatMap(role => role.arn)
    let resolvedPlatformApiEndpoint = clientPlatformApi->Pulumi.Output.flatMap(api =>
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

    // ── Declared object stores ────────────────────────────────────────────
    //
    // The store a field declares is the store that gets provisioned. Before
    // this, a `@storageRef("productImages")` annotation and a hand-written
    // bucket name were two unrelated strings: deleting the annotation left the
    // bucket, and adding one provisioned nothing.
    //
    // Provisioned here, in the platform deploy, rather than in each plugin's
    // stack. Three things force it: the serving CDN lives here, the presign
    // services live here, and a shared-layout bucket has several plugins'
    // stores in it, so no single plugin stack can own it. Ownership is carried
    // in the tags instead — a per-store bucket is tagged to the plugin whose
    // field declared it; a shared bucket is platform substrate, because that is
    // what it is.
    let stackName = Pulumi.Pulumi.getStackName()
    let storeLayout = Util_StoreLayout.layoutFor(
      ~stack=stackName,
      ~prodStacks=Util_HostUiDomain.resolveProdStacks(),
    )
    let storeProtection = Util_StoreLayout.protectionFor(~stack=stackName)

    // Dedup by `(plugin, store)` — that pair is a store's identity, and many
    // fields legitimately name one store.
    let declaredStores =
      capabilities
      ->Array.filterMap(c =>
        switch c {
        | ObjectStore({plugin, store}) => Some((plugin, store))
        | Geocoding => None
        }
      )
      ->Array.reduce([], (acc, (plugin, store)) =>
        acc->Array.some(((p, s)) => p == plugin && s == store)
          ? acc
          : Array.concat(acc, [(plugin, store)])
      )

    // Refuse two stores that cannot be told apart, BEFORE a single resource is
    // created. Left to the deploy, the same collision surfaces as a CloudFront
    // error about a duplicate path pattern — minutes in, naming a path pattern
    // rather than the two plugins — and only after the intermixed objects and
    // the over-broad presign grant have already been provisioned.
    //
    // Checked on the prefix, so it costs nothing to keep once prefixes are
    // qualified: a qualified prefix simply stops colliding, while the check
    // still guards any bare prefix that outlives the change.
    switch ReventlessCore.StorePrefixCollision.collisionsFor(
      ~stores=declaredStores->Array.map(((plugin, store)) => {
        ReventlessCore.StorePrefixCollision.qualified: `${plugin}.${store}`,
        prefix: Util_StoreLayout.keyPrefixFor(~plugin, ~store),
      }),
    ) {
    | [] => ()
    | collisions =>
      JsError.throwWithMessage(
        collisions
        ->Array.map(ReventlessCore.StorePrefixCollision.collisionMessage)
        ->Array.join("\n\n"),
      )
    }

    if declaredStores->Array.length > 0 {
      // The fail-open in `layoutFor` is only dangerous while it is silent: a
      // production stack that is not on the prod list gets the shared layout and
      // nothing errors. Log the choice on every deploy so it surfaces the first
      // time it happens rather than at an audit.
      log.info(
        ~comp="Platform:deployPlatform",
        `object stores: ${switch storeLayout {
          | PerStore => "bucket per store"
          | SharedBucket => "shared bucket, {store}/… prefixes"
          }}, ${switch storeProtection {
          | Protected => "protected"
          | Unprotected => "unprotected (disposable stack)"
          }} — stack ${stackName}`,
      )
    }

    // One bucket per *physical name*, which is one per store under `PerStore`
    // and one for the whole stack under `SharedBucket`. Grouped rather than
    // mapped because those cardinalities differ, and a bucket carries only one
    // policy and one CDN origin however many stores live in it.
    let storeBuckets: Dict.t<ReventlessInfra.Platform.objectStore> = Dict.make()
    let storeBucketOrder: array<string> = []

    // Which stores expire their never-claimed uploads, grouped by the bucket
    // they live in. Computed before any bucket is created, because a bucket
    // carries its lifecycle rules from birth and a shared-layout bucket is
    // created once for several stores — the first store through the loop below
    // would otherwise be the only one whose setting was ever read.
    //
    // Off unless a deployment names the store. See `Util_StoreLayout.pendingExpiryFor`
    // for why this is a deployment's setting and not a declaration's, and why
    // there is deliberately no default.
    let pendingExpiryConfig = Util_LocalConfig.get("pendingUploadExpiryDays")
    let pendingExpiryByBucket: Dict.t<array<Capability_ObjectStore_S3.pendingExpiry>> = Dict.make()
    declaredStores->Array.forEach(((plugin, store)) =>
      Util_StoreLayout.pendingExpiryFor(
        ~config=pendingExpiryConfig,
        ~store=`${plugin}.${store}`,
      )->Option.forEach(days => {
        let bucketName = Util_StoreLayout.bucketNameFor(
          ~layout=storeLayout,
          ~stack=stackName,
          ~plugin,
          ~store,
        )
        let prefix = Util_StoreLayout.keyPrefixFor(~plugin, ~store)
        pendingExpiryByBucket->Dict.set(
          bucketName,
          pendingExpiryByBucket
          ->Dict.get(bucketName)
          ->Option.getOr([])
          ->Array.concat([{Capability_ObjectStore_S3.prefix, days}]),
        )
        log.info(
          ~comp="Platform:deployPlatform",
          `object store ${plugin}.${store}: never-claimed uploads under ${prefix}/ expire after ` ++
          `${days->Int.toString} days. Claimed objects and objects minted before the claim ` ++
          `component existed carry no pending tag and are outside the rule.`,
        )
      })
    )

    let declaredStoreServices = declaredStores->Array.map(((plugin, store)) => {
      let bucketName = Util_StoreLayout.bucketNameFor(
        ~layout=storeLayout,
        ~stack=stackName,
        ~plugin,
        ~store,
      )
      let keyPrefix = Util_StoreLayout.keyPrefixFor(~plugin, ~store)
      let bucket = switch storeBuckets->Dict.get(bucketName) {
      | Some(b) => b
      | None =>
        let b = Capability_ObjectStore_S3.make(
          ~name=bucketName,
          ~keyPrefix,
          // A shared bucket belongs to no single plugin; a dedicated one does.
          ~plugin=?switch storeLayout {
          | PerStore => Some(plugin)
          | SharedBucket => None
          },
          ~protect=storeProtection == Protected,
          // A protected bucket blocks `pulumi destroy`, so protecting a
          // disposable stack would leak exactly the buckets sharing exists to
          // save. The two settings are opposite faces of one decision.
          ~forceDestroy=storeProtection == Unprotected,
          ~expirePending=pendingExpiryByBucket->Dict.get(bucketName)->Option.getOr([]),
        )
        storeBuckets->Dict.set(bucketName, b)
        storeBucketOrder->Array.push(bucketName)
        b
      }
      let storeHandle = bucket->Capability_ObjectStore_S3.underPrefix(~keyPrefix)
      // `bucketName` is the layout's *logical* name and groups the served view
      // below; `storeHandle.bucketName` is the physical one Pulumi resolves, and
      // is what a consumer needs to build an ARN. Carrying both is the point —
      // they are different strings and only one of them exists in S3.
      //
      // Presigning is no longer per store: one platform-API Upload service (below)
      // covers every declared store, keyed by the qualified `{plugin}.{store}` name.
      (`${plugin}.${store}`, keyPrefix, bucketName, storeHandle.bucketName)
    })

    // Group the served view by bucket: one origin and one bucket policy per
    // bucket, carrying every prefix served from it.
    let declaredServedBuckets = storeBucketOrder->Array.filterMap(bucketName =>
      storeBuckets
      ->Dict.get(bucketName)
      ->Option.map(b => {
        ReventlessInfra.Platform.id: bucketName,
        prefixes: declaredStoreServices
        ->Array.filterMap(((_, prefix, bn, _)) => bn == bucketName ? Some(prefix) : None),
        bucketId: b.bucketId,
        bucketArn: b.bucketArn,
        bucketRegionalDomainName: b.bucketRegionalDomainName,
      })
    )

    // ── Serving the declared stores ───────────────────────────────────────
    //
    // A store's bucket blocks public policy and takes its read grant only from
    // a distribution's BucketPolicy, so "provisioned" and "readable" are two
    // different things. When a host UI bundle is deployed, its distribution
    // fronts the stores same-origin (below) and a relative `/{prefix}/…`
    // resolves with no base URL. When it is not, the platform fronts them
    // itself — otherwise every declared store is write-only.
    //
    // Never both: two distributions fronting one bucket would each write the
    // bucket's single allowed policy and silently unpick the other's grant.
    // `Util_StoreLayout.servingFor` is where that exclusion is decided, so it is
    // one testable choice rather than a condition spelled out here.
    let storeServingBaseUrl: option<Pulumi.Output.t<string>> = switch Util_StoreLayout.servingFor(
      ~hasHostUiBundle=hostUiBundle->Option.isSome,
      ~declaredBucketCount=declaredServedBuckets->Array.length,
    ) {
    | NoStores | HostShell => None
    | PlatformOwned =>
      Some(
        Plugin_Stack.makeServedBucketDistribution(
          ~name="object-stores",
          ~servedBuckets=declaredServedBuckets,
        ),
      )
    }

    let declaredStoreEndpoints = declaredStoreServices->Array.map(((
      store,
      keyPrefix,
      _logicalBucketName,
      physicalBucketName,
    )) => {
      store,
      keyPrefix,
      bucketName: physicalBucketName->Pulumi.Output.fromInput,
      baseUrl: storeServingBaseUrl,
    })
    objectStoreEndpointsRef := declaredStoreEndpoints

    // One domain-API Upload service (route B1) covers every declared store plus the
    // legacy `hostUiBundle.uploadBucket`, keyed by the qualified `{plugin}.{store}` name
    // the caller passes as the `store` argument. On the domain API (not the Admin-gated
    // platform API — see the plan's "Which API" note) so any authenticated user can
    // mint/release. Created here in the outer scope — not inside the `hostUiBundle`
    // branch — because a platform whose UI ships from another stack still has declared
    // stores that need presigning. `uploads` keys the legacy store, matching the prefix
    // it has always served under.
    let uploadServiceStores =
      declaredStoreServices
      ->Array.map(((qualified, keyPrefix, _logical, physicalBucketName)) => {
        Upload_Presign_S3.qualified: qualified,
        bucketName: physicalBucketName,
        servedPrefix: keyPrefix,
      })
      ->Array.concat(
        switch hostUiBundle->Option.flatMap(c => c.uploadBucket) {
        | Some(store) => [
            {
              Upload_Presign_S3.qualified: store.keyPrefix,
              bucketName: store.bucketName,
              servedPrefix: store.keyPrefix,
            },
          ]
        | None => []
        },
      )
    if uploadServiceStores->Array.length > 0 {
      let _uploadService = Upload_Presign_S3.make(
        ~api=domainApi,
        ~stores=uploadServiceStores,
        ~opts={},
      )
    }

    // Exported unconditionally — the provisioning above already is. Their only
    // consumers used to sit inside `switch hostUiBundle`, which left a platform
    // whose UI ships from another stack holding stores it could not name.
    //
    // Omitted entirely when nothing is declared, so a deployment with no
    // declared store keeps a byte-identical output set. The presign endpoint is no
    // longer exported — under route B the client calls the platform API's
    // `Upload_Presign` mutation, so there is no per-store URL to publish.
    if declaredStoreEndpoints->Array.length > 0 {
      Pulumi.Pulumi.export(
        "objectStores",
        declaredStoreEndpoints
        ->Array.map(e =>
          Pulumi.Output.all2((e.bucketName, e.baseUrl->Pulumi.Output.allOpt))->Pulumi.Output.apply(((
            bucketName,
            baseUrl,
          )) => (e, bucketName, baseUrl))
        )
        ->Pulumi.Output.all
        ->Pulumi.Output.apply(resolved =>
          resolved
          ->Array.map(((e, bucketName, baseUrl)) => (
            e.store,
            [
              ("bucketName", JSON.Encode.string(bucketName)),
              ("keyPrefix", JSON.Encode.string(e.keyPrefix)),
            ]
            // Absent when the host shell serves the store: there the object is
            // addressable same-origin and a base URL would be a second, and
            // wrong, way to reach it.
            ->Array.concat(
              switch baseUrl {
              | Some(b) => [("baseUrl", JSON.Encode.string(b))]
              | None => []
              },
            )
            ->Dict.fromArray
            ->JSON.Encode.object,
          ))
          ->Dict.fromArray
          ->JSON.Encode.object
        ),
      )
    }

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

      // A served store is fronted under exactly the prefix the presign service
      // roots its keys at, read from the service's own constant. This is the
      // whole reason the store arrives as one value: the app no longer restates
      // the prefix, so it cannot restate it wrongly.
      //
      // The legacy hand-configured store is served alongside the declared ones,
      // not replaced by them. Refs live in an append-only event log, so the
      // `/uploads/…` values already written there can never be rewritten;
      // `uploads` is therefore treated as a store that happens to predate the
      // declaration, and keeps its prefix permanently.
      let servedBuckets = Array.concat(
        switch cfg.uploadBucket {
        | Some(store) => [
            {
              ReventlessInfra.Platform.id: store.keyPrefix,
              prefixes: [store.keyPrefix],
              bucketId: store.bucketId,
              bucketArn: store.bucketArn,
              bucketRegionalDomainName: store.bucketRegionalDomainName,
            },
          ]
        | None => []
        },
        declaredServedBuckets,
      )

      let {distributionUrl, bucketName} = Plugin_Stack.makeUiBundleDistribution(
        ~pluginId="host-ui",
        ~bundleVersion=cfg.bundleVersion->Option.getOr(version),
        ~assetsDir=cfg.assetsDir->Option.getOr(
          Util_Bundle.resolvePackageRoot(
            ~fromPulumiProject=true,
            "@reventlessdev/reventless-host-shell",
          ) ++ "/dist",
        ),
        ~spaFallback=true,
        ~stableName=true,
        // The explicit BucketObjects below write the production config.json
        // (resolved API endpoints + Cognito IDs) and, when configured, a
        // ui-hints.json. The host-shell bundle's public/config.json and
        // public/ui-hints.json are dev-mode fallbacks — exclude them from the
        // bundle upload so the explicit BucketObjects don't race the bundle on
        // the same S3 keys.
        ~excludeFiles=["config.json", "ui-hints.json"],
        ~customDomain?,
        // Served buckets front the host-shell distribution with `{prefix}/*`
        // read paths (private, OAC-read) — same origin as the SPA, so served
        // objects are addressable by same-origin relative URL with no config.json
        // change. No upload store ⇒ [] ⇒ distribution byte-identical to today.
        ~servedBuckets,
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

      // The geocoding capability's client door (D9 half 2): a `Query.geocode`
      // resolver on the domain API, provisioned only when a place index is
      // configured. Authenticated by the API's Cognito authorizer, so it replaces
      // the public unauthenticated Function URL the browser used to call — after
      // which that endpoint has no callers at all (the unattended slice path reaches
      // the same index through the SDK, via `geocoderPlaceIndex` below).
      //
      // Split-API only, for the same reason the upload resolvers are: `geocode`
      // lives on the domain base document (`domainBaseFragment`), which a
      // unified-mode deployment's single API does not carry.
      switch cfg.geocoderPlaceIndex {
      | Some(index) if Config.splitApi =>
        let _geocodeService = Geocoder_AwsLocation_Resolver.make(
          ~api=domainApi,
          ~placeIndexName=index.indexName,
          ~opts={},
        )
      | _ => ()
      }

      // The place index itself, exported so the unattended slice path can reach the
      // capability: a slice's Lambda signs an SDK call directly and needs the index
      // name, not an endpoint (no proxy hop, no dependence on a public URL). The
      // browser reaches the same capability through the `Query.geocode` resolver
      // above. `""` when unset, so a plugin stack reading this output has one shape
      // to handle rather than two.
      let geocoderPlaceIndexFlat = switch cfg.geocoderPlaceIndex {
      | Some(index) => index.indexName->Pulumi.Output.fromInput
      | None => Pulumi.Output.make("")
      }
      Pulumi.Pulumi.export("geocoderPlaceIndex", geocoderPlaceIndexFlat)
      geocoderPlaceIndexRef := geocoderPlaceIndexFlat

      // Presign endpoints are no longer written to config.json: under route B the
      // client calls the platform API's `Upload_Presign` mutation (reachable from
      // `platformApiEndpoint`, already present) with the store it declares, so there
      // is no per-store URL to publish. The store's *serving* base URL still travels
      // in the `objectStores` stack output above.
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
          let computed = [
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
              computed,
              [
                ("domainApiEventsEndpoint", JSON.Encode.string(ep)),
                ("platformApiEventsEndpoint", JSON.Encode.string(ep)),
                // Capability gate: present iff the API carries the
                // client-publishable namespace — clients hide publish-dependent
                // features (presence, transient chat) when absent.
                (
                  "clientEventsNamespace",
                  JSON.Encode.string(AppSync_EventsApi.clientNamespaceName),
                ),
              ],
            )
          | None => computed
          }
          // `geocoderEndpoint` is no longer written: the browser reaches geocoding
          // through the platform API's `Query.geocode` resolver (D9 half 2), the
          // same way uploads moved off a per-store URL onto `Upload_Presign`. The
          // public Function URL and its config key are both gone.
          Util_ShellConfig.fields(
            ~computed=withEvents,
            ~viewModes=?cfg.viewModes,
            ~shellConfig=?cfg.shellConfig,
          )
          ->JSON.Encode.object
          ->JSON.stringify
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

      // Optional static AutoUI hints. Read + JSON-validated at deploy time
      // (a malformed file fails the deploy rather than shipping a file the
      // shell warn-and-ignores), then written verbatim beside config.json.
      // Unset ⇒ nothing written ⇒ GET /ui-hints.json 404 ⇒ shell boots
      // unchanged, byte-identical to a hints-less deploy.
      switch cfg.uiHintsFile {
      | None => ()
      | Some(hintsPath) =>
        let hintsContent = Util_StaticBundle.readJsonFileVerbatim(
          ~path=hintsPath,
          ~label="host-ui ui-hints",
        )
        let _ = PulumiAws.S3.BucketObject.make(
          ~name="host-ui-ui-hints-json",
          ~args={
            bucket: bucketName->Pulumi.Output.asInput,
            key: Pulumi.Input.make("ui-hints.json"),
            content: Pulumi.Input.make(hintsContent),
            contentType: Pulumi.Input.make("application/json"),
          },
        )
      }

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

    // Register the deploy-time offload hook so Plugin_Builder content-addresses
    // the two large pluginDefinition fields (`structure`, `apiSchemaFragment`)
    // into the platform's offload bucket and carries them as references instead
    // of inline. The hook fires synchronously during P.make() (both values are
    // concrete at graph construction), writing a content-addressed BucketObject
    // and returning its ref; cleared after the build so nothing else offloads.
    // The bucket name comes from the platform stack (deploy the platform first).
    let offloadBucketName: Pulumi.Output.t<string> = switch platformStackRef {
    | Some(stackRef) =>
      (stackRef->Pulumi.StackReference.getOutput("offloadBucket"): Pulumi.Output.t<option<string>>)
      ->Pulumi.Output.apply(o => o->Option.getOr("OFFLOAD_BUCKET_PENDING_PLATFORM_DEPLOY"))
    | None => Pulumi.Output.make("OFFLOAD_BUCKET_PENDING_PLATFORM_DEPLOY")
    }
    ReventlessCore.Plugin_Helpers.registerOffload((~store, ~bytes) => {
      let hash = NodeCrypto.sha256Hex(bytes)
      let key = "sha256/" ++ hash
      // Content-addressed: the name and key are the hash, so re-deploying an
      // unchanged field writes the same object (idempotent, deduplicating).
      let _ = PulumiAws.S3.BucketObject.make(
        ~name="offload-" ++ hash,
        ~args={
          bucket: offloadBucketName->Pulumi.Output.asInput,
          key: Pulumi.Input.make(key),
          content: Pulumi.Input.make(bytes),
          contentType: Pulumi.Input.make("application/json"),
        },
      )
      {Reventless.Offload.store, key, hash, bytes: bytes->String.length}
    })

    // Capability endpoints the platform provisioned, handed to this plugin's
    // slice Lambdas as environment. Read across the stack reference in plugin
    // mode and out of the platform's own record when platform and plugin are one
    // program — the same two halves the offload bucket above is read through.
    //
    // Registered before `P.make()`: the slice runtime finalizers fire from inside
    // the plugin build, and a variable registered after it would be built into
    // nothing.
    //
    // A platform that provisioned no geocoder yields "", and the plugin's client
    // reports `Unavailable` — retried, then surfaced by the heartbeat sweep. That
    // is a modelled outcome, which is the point of the empty string: a plugin
    // deployed against a platform without the capability degrades rather than
    // failing to deploy.
    // The place index, not the Function URL. A slice's Lambda reaches Amazon
    // Location through the SDK now, so what it needs is the index's name — and
    // the grant that goes with it, which is why this is also handed to
    // `registerGeocoderPlaceIndex` rather than only to the environment. The
    // browser keeps using the Function URL until the platform API carries a
    // geocode field; the two doors are independent.
    let geocoderPlaceIndex: Pulumi.Output.t<string> = switch platformStackRef {
    | Some(stackRef) =>
      (
        stackRef->Pulumi.StackReference.getOutput("geocoderPlaceIndex"):
          Pulumi.Output.t<option<string>>
      )->Pulumi.Output.apply(o => o->Option.getOr(""))
    | None => geocoderPlaceIndexRef.contents
    }
    PluginRuntime_Builder.registerCapabilityEnv("PLACE_INDEX_NAME", geocoderPlaceIndex)
    PluginRuntime_Builder.registerGeocoderPlaceIndex(geocoderPlaceIndex)

    module P = unpack(plugin)
    let pluginComponent = P.make()
    ReventlessCore.Plugin_Helpers.clearOffload()
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

    // ── Merged-API association (merged-api plan, Phase 4) ───────────────────
    // Associate this plugin's source API with the platform's merged API —
    // this replaces the SigV4 RegisterApiFragment handshake + reactive push +
    // waiter as the schema-composition mechanism. `pulumi destroy` deletes
    // the association + source API: retirement by construction. Create-time
    // 409s (AWS serializes association creates per merged API) surface as a
    // deploy failure — retry concurrent FIRST-TIME plugin deploys; steady-
    // state schema updates never re-create the association.
    switch platformStackRef {
    | Some(stackRef) =>
      let defaultOutput: Pulumi.Output.t<option<JSON.t>> =
        stackRef->Pulumi.StackReference.getOutput("default")
      let getMergedExport = (key: string): Pulumi.Output.t<string> => {
        let direct: Pulumi.Output.t<option<string>> =
          stackRef->Pulumi.StackReference.getOutput(key)
        (direct, defaultOutput)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((direct, default)) =>
          switch direct {
          | Some(v) => v
          | None =>
            default
            ->Option.flatMap(d => d->JSON.Decode.object)
            ->Option.flatMap(d => d->Dict.get(key))
            ->Option.flatMap(v => v->JSON.Decode.string)
            ->Option.getOrThrow(
              ~message=`Platform stack does not export '${key}' — deploy the platform with mergedApi=true first`,
            )
          }
        )
      }
      // apiTarget collapses to "which merged API ARN the association points at".
      let mergedApiArn = switch apiTarget {
      | Domain => getMergedExport("domainMergedApiArn")
      | Platform => getMergedExport("platformMergedApiArn")
      }
      // Primary-auth contract check (checked invariant, not a convention) —
      // folded into the ARN the association consumes so it always runs.
      let checkedMergedApiArn =
        (mergedApiArn, getMergedExport("mergedApiPrimaryAuth"))
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((arn, mergedMode)) => {
          AppSync_MergedApi.assertCompatiblePrimaryAuth(
            ~sourceMode=AppSync_MergedApi.authenticationTypeName(
              AppSync_Adapter.primaryAuthenticationType,
            ),
            ~mergedMode,
          )
          arn
        })
      // Sequence the association behind the subgraph schema push (the
      // intra-stack replacement of the schemaPushed cross-stack gate).
      let schemaPushed = switch mergedSchemaPushedRef.contents {
      | Some(pushed) => pushed
      | None => Pulumi.Output.make()
      }
      let arnAfterSchemaPush =
        (checkedMergedApiArn, schemaPushed)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((arn, _)) => arn)
      let association = AppSync_MergedApi.associateSourceWithMergedArn(
        ~name="PluginSourceAssociation",
        ~mergedApiArn=arnAfterSchemaPush,
        ~sourceApi=domainApi,
        ~opts={},
      )
      // Fail the deploy loudly on MERGE_FAILED — the gate is folded into the
      // exported association id so it is always consumed.
      let mergeGate = AppSync_MergedApi.mergeStatusGateWith(
        ~mergedApiIdentifier=checkedMergedApiArn,
        ~association,
      )

      // ── Capability coverage ────────────────────────────────────────────────
      //
      // `requiredStores` is what this plugin's fields *declare*; the platform's
      // `objectStores` output is what it actually provisioned. A store in the
      // first and not the second is the split-stack ordering hazard: the
      // platform deploys before the plugin and cannot see the plugin's schemas,
      // so the capability list is hand-written and can simply be wrong.
      //
      // It is worth failing on because every symptom is silent. The upload
      // input finds no per-store endpoint, falls back to the legacy single
      // service, and writes to whatever bucket that serves — a 2xx, a plausible
      // ref, and the wrong destination. A case slip in the hand-written name
      // produces exactly that, and so does forgetting the entry entirely.
      //
      // Two outcomes rather than one, because "you got it wrong" and "you have
      // not started" deserve different answers. A platform exporting no stores
      // at all has not adopted capability provisioning; failing it would break
      // deployments that are working. A platform exporting *some* stores but
      // not this one has adopted it and is missing or misspelling an entry.
      //
      // Folded into the association export for the same reason the merge gate
      // is: a dangling `apply` is not guaranteed to be evaluated, and a check
      // that might not run is not a check.
      let capabilityGate: Pulumi.Output.t<unit> =
        (pluginOutputs.pluginStructure, stackRef->Pulumi.StackReference.getOutput("objectStores"))
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply((((structure, objectStores): (_, option<JSON.t>))) => {
          let required =
            structure->Option.flatMap(s => s.requiredStores)->Option.getOr([])
          let provisioned =
            objectStores
            ->Option.flatMap(JSON.Decode.object)
            ->Option.map(Dict.keysToArray)
            ->Option.getOr([])
          switch Util_StoreLayout.coverageFor(~required, ~provisioned) {
          | Covered => ()
          | NotAdopted(missing) =>
            log.warn(
              ~comp="Platform:deployPlugin",
              `declares ${missing->Array.join(", ")} but the platform stack provisions no object stores — ` ++
              `add them to the platform's ~capabilities and redeploy the platform first, ` ++
              `or uploads will fall back to the legacy service and write to the wrong bucket`,
            )
          | Missing({missing, provisioned}) =>
            JsError.throwWithMessage(
              `Plugin requires object store(s) the platform does not provision: ${missing->Array.join(", ")}.\n` ++
              `  The platform stack provisions: ${provisioned->Array.join(", ")}.\n` ++
              `  A store's key is {plugin}.{store}, where {plugin} is the name the plugin registers — ` ++
              `check the capability's spelling and case against it.\n` ++
              `  Add the missing entr(ies) to the platform's ~capabilities and redeploy the platform stack first.`,
            )
          }
        })

      Pulumi.Pulumi.export(
        "sourceApiAssociationId",
        (association.associationId, mergeGate, capabilityGate)
        ->Pulumi.Output.all3
        ->Pulumi.Output.apply(((id, _, _)) => id),
      )
      Pulumi.Pulumi.export(
        "pluginSourceApiId",
        domainApi->Pulumi.Output.flatMap(api => api.id),
      )
      Pulumi.Pulumi.export(
        "pluginSourceApiEndpoint",
        domainApi->Pulumi.Output.flatMap(api =>
          api.uris->Pulumi.Output.apply(uris => uris.graphQL)
        ),
      )
    | _ => ()
    }

    // B2.3d: provision the Postgres change-feed relay (plugin-stack mode — this
    // plugin's Postgres DCB log(s) + collector queue were registered during P.make()).
    provisionPgChangeFeedRelay()

    // B3.2b/c: provision this plugin stack's PgQueryResolver Lambda + AppSync data
    // source for its Postgres-backed read models (registered during P.make()).
    // Resolvers attach to this plugin's own source API.
    switch QueryDbBackend.get() {
    | Some(sel) => PgQueryResolver_Builder.provision(~api=domainApi, ~selection=sel, ~opts={})
    | None => ()
    }

    // Zero-downtime handover (Part 3.1): fire ONE synthetic re-detect for the
    // just-deployed plugin so its new version runs the connect handshake within
    // seconds instead of waiting for the CloudWatch heartbeat rule's first
    // natural tick (up to `heartbeatTimeout` minutes). Uses `RedetectPlugin` rather
    // than a keep-alive `Heartbeat` so an already-connected version re-runs the
    // handshake and refreshes its stored definition on the lifecycle row (e.g. a
    // newly added `kind`) — a plain heartbeat no-ops a connected version and would
    // never re-serialize the def. Routes through the exact runtime path — a command
    // (id = name@version) onto the EP FIFO command-topic queue — mirroring
    // HeartbeatEntryPoint.mjs and reusing CommandTopicChannel_SQS_Runtime.publishJsons
    // (correct FIFO message-group handling). If it no-ops (config missing / send
    // fails) the handover still completes on the next natural heartbeat — graceful
    // degradation.
    // heartbeatConfigRef holds the just-built plugin's config (deployPlugin builds
    // exactly one plugin per call), but it is written from the
    // onHeartbeatEpChannelAvailable hook, which core fires from inside the deferred
    // construct callback — after `P.make()` has returned. Reading it here
    // synchronously always saw the initial empty config, so the publish was skipped
    // on every deploy. `pluginOutputs.heartbeat` derives from that same callback's
    // output, so applying to it is the earliest point the config is populated.
    let _ = pluginOutputs.heartbeat->Pulumi.Output.apply(_ => {
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
            commandJson: ReventlessInfra.PluginExtensionPointSpec.RedetectPlugin(
              hbConfig.heartbeatTimeout,
            )->S.reverseConvertToJsonOrThrow(ReventlessInfra.PluginExtensionPointSpec.commandSchema),
          }
          try {
            await publishHeartbeat([message])
            log.info(
              ~comp="Platform:deployPlugin",
              `synthetic re-detect published for ${hbConfig.pluginId}`,
            )
          } catch {
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
    })

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
