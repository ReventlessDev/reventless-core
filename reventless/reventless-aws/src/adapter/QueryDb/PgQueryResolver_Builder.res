// Deploy-time provisioner for the shared Postgres GraphQL-read Lambda (B3.2b).
//
// Postgres-backed read models have no per-table AppSync data source, so instead
// of the direct DynamoDB resolvers there is ONE in-VPC "PgQueryResolver" Lambda
// (PgQueryResolverEntryPoint.mjs → PgQueryResolver_Lambda.dispatch) registered
// as a single AppSync Lambda data source. Every Postgres read model's resolvers
// (QueryDbResolvers_Lambda) are thin APPSYNC_JS `Invoke` templates pointing at
// this one data source.
//
// Ordering wrinkle: `QueryDbStorage_Postgres.make` runs DURING construct and
// must return the data source name, but the Lambda's code bundle needs the set
// of Postgres read models (their spec packages), known only AFTER construct. So
// the data source name is a DEFERRED Output (`dataSourceName`), fulfilled by
// `provision` — which the platform calls in makePlatform once every plugin is
// built (alongside provisionPgChangeFeedRelay). The resolvers themselves are
// created even later (inside the schema-pushed `resourcesMaker`), so they read
// the name after `provision` has resolved it.

open PulumiAws

let log = ReventlessCore.Logger.fromEnv()

// -- Deferred data source name ----------------------------------------------
// Created once at module load. `QueryDbStorage_Postgres.make` returns this for
// every Postgres read model (one shared data source); `provision` resolves it.
let resolveDataSourceName: ref<string => unit> = ref(_ => ())
let dataSourceNamePromise: promise<string> = Promise.make((resolve, _reject) =>
  resolveDataSourceName := resolve
)
let dataSourceName: Pulumi.Output.t<string> = Pulumi.Output.fromPromise(dataSourceNamePromise)

// -- Resolver-binding registry ----------------------------------------------
// Populated by QueryDbResolvers_Lambda.make during construct (per Postgres read
// model): the bits `provision` bakes into the Lambda env config that the entry
// point can't get from the spec module (they come from the deploy-time
// queryFieldNamesRegistry). specModulePath is looked up from
// EventCollectorRuntime_Builder_Single.readModelInfos at provision time.
type resolverEntry = {
  readModelName: string,
  labelField: string,
  includeIdParam: bool,
}
let entries: dict<resolverEntry> = Dict.make()
let register = (entry: resolverEntry): unit =>
  entries->Dict.set(entry.readModelName, entry)

// -- Provision --------------------------------------------------------------
let bool = b => b ? "true" : "false"

// Serialize the shared connection config into the env-config JSON (same shape
// EventCollectorRuntime_Builder_Single bakes into HANDLER_CONFIG).
let pgConnectionJson = (cc: PgConnection.connectionConfig): string =>
  [
    ("host", cc.host->JSON.Encode.string),
    ("port", cc.port->Int.toFloat->JSON.Encode.float),
    ("database", cc.database->JSON.Encode.string),
    ("username", cc.username->JSON.Encode.string),
    ("secretArn", cc.secretArn->JSON.Encode.string),
  ]
  ->Dict.fromArray
  ->JSON.Encode.object
  ->JSON.stringify

let provision = (
  ~api: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  ~selection: QueryDbBackend.selection,
  ~opts: Pulumi.ComponentResource.options,
): unit => {
  // Join the resolver-binding registry (labelField/includeIdParam) with the
  // ReadModel runtime registry (specModulePath, pgBacked). Only read models
  // that both got Lambda resolvers AND are Postgres-backed are handled here.
  let handlers =
    entries
    ->Dict.valuesToArray
    ->Array.filterMap(entry =>
      switch EventCollectorRuntime_Builder_Single.readModelInfos->Dict.get(entry.readModelName) {
      | Some(info) if info.pgBacked => Some((entry, info.specModulePath))
      | _ => None
      }
    )
  if handlers->Array.length == 0 {
    // No Postgres read models with Lambda resolvers — nothing to provision.
    ()
  } else {
    // makeFromCodeAsset takes ComponentResource.options (the original); the raw
    // IAM / DataSource resources take the CustomResourceOptions projection.
    let customOpts =
      opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
    let name = "PgQueryResolver"

    // Bundle the entry point plus each read model's spec package (imported at
    // Lambda init for indexes / subIdField / schema → capability).
    let packageDirs: dict<string> = Dict.make()
    handlers->Array.forEach(((_entry, specModulePath)) => {
      let pkg = Util_Bundle.extractPackageName(specModulePath)
      packageDirs->Dict.set(pkg, Util_Bundle.resolvePackageRoot(pkg))
    })

    // Env config: shared pgConnection + one handler per read model. Sorted for
    // deploy-stable output. specModule/labelField/includeIdParam are baked;
    // indexes/subIdField/authorization come from the imported spec at runtime.
    let handlerJsons =
      handlers
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a.readModelName, b.readModelName))
      ->Array.map(((entry, specModulePath)) => {
        let specModule = specModulePath->JSON.stringifyAny->Option.getOr(`""`)
        `{"readModelName":"${entry.readModelName}","specModule":${specModule},"labelField":"${entry.labelField}","includeIdParam":${bool(
            entry.includeIdParam,
          )}}`
      })

    let queryResolverConfig =
      selection.connectionConfig->Pulumi.Output.apply(cc =>
        `{"pgConnection":${pgConnectionJson(cc)},"handlers":[${handlerJsons->Array.join(",")}]}`
      )

    let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
    envVars->Dict.set("QUERY_RESOLVER_CONFIG", queryResolverConfig->Pulumi.Output.asInput)
    envVars->Dict.set("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make)

    let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
      ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/PgQueryResolverEntryPoint.mjs",
      ~packageDirs,
    )

    // In-VPC on the DB-access security group + private subnets (reach RDS).
    let vpcConfig =
      selection.securityGroupId
      ->Pulumi.Output.apply(sgId =>
        (
          {
            Lambda.Function.subnetIds: selection.subnetIds->Pulumi.Input.make,
            securityGroupIds: [sgId->Pulumi.Input.make]->Pulumi.Input.make,
          }: Lambda.Function.vpcConfig
        )
      )
      ->Pulumi.Output.asInput

    let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
      ~name,
      ~code,
      ~sourceCodeHash,
      ~envVars,
      ~memorySize=512,
      ~timeout=30,
      ~vpcConfig,
      ~opts,
    )

    // Read the RDS-managed secret so PgRuntime can resolve the DB password.
    let _ = selection.connectionConfig->Pulumi.Output.apply(cc => {
      open PolicyDocument
      IAM.RolePolicy.make(
        ~name=name ++ "-pgSecret",
        ~args={
          policy: PolicyDocument.make(
            ~id=name ++ "-pgSecretPolicy",
            ~statements=[
              {
                sid: "AllowGetPgSecret",
                effect: Allow,
                actions: Action("secretsmanager:GetSecretValue"),
                resources: Resource(cc.secretArn),
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
        },
      )
    })

    // AppSync → Lambda data source (one, shared by every Postgres RM's resolvers).
    let dataSourceRole = IAM.Role.makeWithDefaultPolicy(
      ~name=name ++ "DataSource",
      ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
      ~opts=customOpts,
    )
    let lambdaArn = runtime.parts.lambda->Pulumi.Output.flatMap(l => l.arn)
    let _ =
      (lambdaArn, dataSourceRole.id)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((arn, dsRoleId)) => {
        open PolicyDocument
        IAM.RolePolicy.make(
          ~name=name ++ "DataSourceInvoke",
          ~args={
            policy: PolicyDocument.make(
              ~id=name ++ "DataSourceInvokePolicy",
              ~statements=[
                {
                  sid: "AllowDataSourceInvokeLambda",
                  effect: Allow,
                  actions: Action("lambda:InvokeFunction"),
                  resources: Resource(arn),
                },
              ],
            )
            ->PolicyDocument.toJsonString
            ->Pulumi.Input.make,
            role: dsRoleId->Pulumi.Input.make,
          },
        )
      })

    let dataSource = AppSync.DataSource.make(
      ~name=name ++ "DataSource",
      ~args={
        type_: AWS_LAMBDA,
        apiId: api->Pulumi.Output.flatMap(a => a.id)->Pulumi.Output.asInput,
        lambdaConfig: {
          AppSync.DataSource.functionArn: lambdaArn->Pulumi.Output.asInput,
        }->Pulumi.Input.make,
        serviceRoleArn: dataSourceRole.arn->Pulumi.Output.asInput,
      },
      ~opts=Some(customOpts),
    )

    // Fulfil the deferred name the Postgres storage maker handed to resolvers.
    let _ = dataSource.name->Pulumi.Output.apply(n => resolveDataSourceName.contents(n))
    log.info(~comp="PgQueryResolver_Builder", `provisioned for ${handlers->Array.length->Int.toString} read model(s)`)
  }
}
