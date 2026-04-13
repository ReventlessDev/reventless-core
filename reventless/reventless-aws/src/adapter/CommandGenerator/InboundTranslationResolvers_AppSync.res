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
  ~opts: Pulumi.ComponentResource.options,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda

  let dataSourceRole = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name="InboundTranslationDS",
    ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
    ~opts,
  )

  let _ =
    (
      lambda->Pulumi.Output.flatMap(lambda => lambda.arn),
      dataSourceRole.id,
    )
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((lambdaArn, dataSourceRoleId)) => {
      let _attachDataSourcePolicy = PulumiAws.IAM.RolePolicy.make(
        ~name="InboundTranslationDS",
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
    ~name="InboundTranslation",
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
      ~name=fieldName->String.capitalize,
      ~api,
      ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
      ~type_="Mutation"->Pulumi.Input.make,
      ~field=fieldName->Pulumi.Input.make,
      ~code=PulumiAws.AppSync.Resolver.Functions.invokeInboundTranslation(fieldName),
      ~opts,
    )
  })
}
