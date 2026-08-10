/** Provisions the query-interceptor path on AppSync, when an extension has asked
    for it via `ReventlessCore.QueryInterception.use`.

    The framework owns everything provider-shaped here — the runtime, its
    execution role, the AppSync Lambda data source and the role that lets AppSync
    invoke it — because all of it needs the api handle and a service role, which
    exist only inside the plugin build. An extension supplies none of it; see the
    seam's own docstring for why that split is the point.

    **One interceptor per api, not per read model.** A data source belongs to one
    api, so it is memoised on the api handle *by identity* — the builders thread
    a single `api` value through every read model that resolves against it, and
    identity is what guarantees the data source ends up attached to the very api
    the resolver names. Keying on anything looser (the owning plugin, say) would
    be right until one key spanned two apis, and the failure then is a resolver
    pointing at a data source that does not exist on its api — rejected at deploy
    time, with nothing in the message about why.

    The api's *contents* are an `Output` and are unknown at
    resolver-construction time, which is why the ambient `ResourceAttribution`
    plugin supplies the resource NAMES instead. That is presentation, not
    identity: a second api under one plugin gets a suffixed name rather than a
    shared data source. Substrate built outside any plugin construct (the admin
    read models on the platform api) is named `Platform`.

    The runtime is built through `RuntimeEnvironment_Lambda.makeFromCodeAsset`
    rather than a bespoke `Lambda.Function.make`, which is what makes the seams
    compose: that path bundles registered runtime extensions into the archive and
    writes `RUNTIME_EXTENSIONS`, so an extension registering its interceptor in
    `onColdStart` reaches this runtime without a second registration. */

open PulumiAws

// Memoised on the api handle itself — see the module docstring for why identity
// rather than a name. The value is the data-source name the resolver pipeline
// references.
let byApi: Map.t<Types.AppSync.api, Pulumi.Input.t<string>> = Map.make()

// How many interceptors a given owner already named, so a second api under one
// owner gets a distinct resource name instead of colliding with the first.
let namesUsed: dict<int> = Dict.make()

/** A stable, readable resource-name stem for the interceptor: the owning plugin,
    or `Platform` for substrate provisioned outside any plugin construct. */
let nameFor = () => {
  let owner = ReventlessCore.ResourceAttribution.current.contents.plugin->Option.getOr("Platform")
  let used = namesUsed->Dict.get(owner)->Option.getOr(0)
  namesUsed->Dict.set(owner, used + 1)
  used == 0
    ? owner ++ "QueryInterceptor"
    : owner ++ "QueryInterceptor" ++ (used + 1)->Int.toString
}

let buildInterceptor = (~api: Types.AppSync.api, ~opts) => {
  let name = nameFor()
  let componentOpts: Pulumi.ComponentResource.options = {
    parent: ?(opts: Pulumi.CustomResourceOptions.t).parent,
  }

  let packageDirs = Dict.fromArray([
    (
      "@reventlessdev/reventless-aws",
      Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
    ),
  ])
  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryInterceptor_Lambda.res.mjs",
    ~packageDirs,
  )

  // Sits in front of every read, so it is sized for a decision rather than for
  // work: small memory, short timeout. A hook that needs longer than this is
  // doing something a read path cannot afford anyway.
  let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
    ~name,
    ~unitKind=ReventlessCore.Monitoring.Other("QueryInterceptor"),
    ~componentKind=ReventlessCore.ComponentType.Plugin,
    ~code,
    ~sourceCodeHash,
    ~memorySize=256,
    ~timeout=10,
    ~opts=componentOpts,
  )
  let lambdaArn = runtime.parts.lambda->Pulumi.Output.flatMap(lambda => lambda.arn)

  let dataSourceRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "DataSource",
    ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
    ~tags=AWS.Tags.make(
      ~name=name ++ "DataSource",
      ~kind=ReventlessCore.ComponentType.Plugin,
      ~role=Identity,
      ~scope=Plugin,
    ),
    ~opts,
  )

  let _ =
    (lambdaArn, dataSourceRole.id)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((lambdaArn, dataSourceRoleId)) => {
      open PolicyDocument
      let _attach = IAM.RolePolicy.make(
        ~name=name ++ "DataSource",
        ~args={
          IAM.RolePolicy.policy: PolicyDocument.make(
            ~id=name ++ "DataSourcePolicy",
            ~statements=[
              {
                sid: "AllowDataSourceInvokeInterceptor",
                effect: Allow,
                actions: Action("lambda:InvokeFunction"),
                resources: Resource(lambdaArn),
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: dataSourceRoleId->Pulumi.Input.make,
        },
        ~opts,
      )
    })

  let dataSource = AppSync.DataSource.make(
    ~name=name ++ "DataSource",
    ~args={
      type_: AWS_LAMBDA,
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
      lambdaConfig: {
        AppSync.DataSource.functionArn: lambdaArn->Pulumi.Output.asInput,
      }->Pulumi.Input.make,
      serviceRoleArn: dataSourceRole.arn->Pulumi.Output.asInput,
    },
    ~opts=Some(opts),
  )

  dataSource.name->Pulumi.Output.asInput
}

/** Whether a Query resolver fronts its DynamoDB read with the interceptor, and
    the data source to front it with. `Off` means interception is switched off —
    the caller builds the unit resolver it always did and nothing here is
    provisioned.

    A variant rather than an `option`, and that is load-bearing. The payload is a
    Pulumi `Output`, which is a JS `Proxy` answering *every* property read with a
    derived `Output`. The generic option runtime unwraps by probing the payload
    for `BS_PRIVATE_NESTED_SOME_NONE`; on a `Proxy` that probe never reads
    `undefined`, so it takes the nested-option branch and yields a wrapper object
    where a data-source name belongs. AppSync then rejects the resource with
    "Attribute must be a single value, not a map" — at deploy time, naming a
    field the source never mentions. A variant keeps that runtime off the path
    entirely, so no caller can reintroduce the fault by reaching for
    `Option.map`. */
type t =
  | Off
  | On(Pulumi.Input.t<string>)

let dataSourceName = (~api: Types.AppSync.api, ~opts): t =>
  if !ReventlessCore.QueryInterception.isEnabled() {
    Off
  } else {
    switch byApi->Map.get(api) {
    | Some(existing) => On(existing)
    | None =>
      let created = buildInterceptor(~api, ~opts)
      byApi->Map.set(api, created)
      On(created)
    }
  }
