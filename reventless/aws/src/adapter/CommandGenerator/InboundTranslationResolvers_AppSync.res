// AppSync mutation resolvers for InboundTranslationSlices (AWS).
// Creates an AppSync DataSource + Resolver per InboundTranslationSlice mutation,
// pointing to the shared DCB CommandTopic Lambda.
//
// The request template sends a payload with `__inboundTranslation: true` so the
// Lambda's composite handler routes to InboundTranslationSlice.receive instead
// of the regular SQS command processing.

type runtimeParts = Util.Lambda.runtimeParts

let make = (
  ~api: Types.AppSync.api,
  ~runtime: ReventlessCore.Runtime.environment<runtimeParts>,
  ~fieldNames: array<string>,
  // Set for the doors on the narrow API for visitors: its resources are named
  // apart from the plugin API's, and it has no subscriptions.
  ~forVisitors: bool=false,
  ~opts: Pulumi.ComponentResource.options,
) => {
  let named = (name: string) => forVisitors ? `Visitor${name}` : name
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda

  let dataSourceRole = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name=named("InboundTranslationDS"),
    ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
    ~tags=AWS.Tags.make(
      ~name=named("InboundTranslationDS"),
      ~kind=ReventlessCore.ComponentType.Plugin,
      ~role=Identity,
      ~scope=Plugin,
    ),
    ~opts,
  )

  let _ =
    (lambda->Pulumi.Output.flatMap(lambda => lambda.arn), dataSourceRole.id)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((lambdaArn, dataSourceRoleId)) => {
      let _attachDataSourcePolicy = PulumiAws.IAM.RolePolicy.make(
        ~name=named("InboundTranslationDS"),
        ~args={
          PulumiAws.IAM.RolePolicy.policy: PulumiAws.PolicyDocument.make(
            ~id="InboundTranslationDSPolicy",
            ~statements=[
              {
                sid: "AllowInboundTranslationInvokeLambda",
                effect: Allow,
                actions: Action("lambda:InvokeFunction"),
                resources: Resource(lambdaArn),
              },
            ],
          )
          ->PulumiAws.PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: dataSourceRoleId->Pulumi.Input.make,
        },
        ~opts,
      )
    })

  let dataSource = PulumiAws.AppSync.DataSource.make(
    ~name=named("InboundTranslation"),
    ~args={
      type_: AWS_LAMBDA,
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
      lambdaConfig: {
        PulumiAws.AppSync.DataSource.functionArn: lambda
        ->Pulumi.Output.flatMap(lambda => lambda.arn)
        ->Pulumi.Output.asInput,
      }->Pulumi.Input.make,
      serviceRoleArn: dataSourceRole.arn->Pulumi.Output.asInput,
    },
    ~opts=Some(opts),
  )

  let _resolvers = fieldNames->Array.forEach(fieldName => {
    let _ = AppSync_Resolver_Retrying.makeUnitJsResolver(
      ~name=named(fieldName->String.capitalize),
      ~api,
      ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
      ~type_="Mutation"->Pulumi.Input.make,
      ~field=fieldName->Pulumi.Input.make,
      ~code=PulumiAws.AppSync.Resolver.Functions.invokeInboundTranslation(fieldName),
      ~opts,
    )
  })

  // Source C: create the matching `onX` Subscription resolver for each
  // mutation field so SDL fields like `onCatalog_ImportProduct` emitted by
  // Plugin_SubscriptionSchema are actually attached. Mirrors what
  // CommandGeneratorResolvers_AppSync.make / makeDcb do for aggregate / DCB
  // mutations. Reuses the mutation's data source — UNIT subscription code
  // never executes against it.
  if !forVisitors {
    CommandSubscriptionResolvers_AppSync.make(
      ~api,
      ~mutationFields=fieldNames,
      ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
      ~opts,
    )
  }
}
