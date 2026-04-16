type api = Types.AppSync.api
type runtimeParts = Util.Lambda.runtimeParts

let handleResolversEvent = (generateCommand: ReventlessCore.CommandGenerator.commandGenerator) =>
  Pulumi.Output.make((event, _context) => event->generateCommand)

let make: ReventlessCore.CommandGenerator_Adapter.resolversMaker<api, Util.Lambda.runtimeParts> = (
  ~name: string,
  ~api: api,
  ~fields,
  ~commandSchema as _,
  ~runtime,
  ~resources: array<ReventlessInfra.Adapter.resource>,
  ~opts,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let dataSourceRole = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "DataSource",
    ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
    ~opts,
  )

  let _ =
    (
      lambda->Pulumi.Output.flatMap(lambda => lambda.arn),
      lambda->Pulumi.Output.flatMap(lambda => lambda.name),
      lambdaRole.id,
      resources->ReventlessCore.Adapter.resourcesToResolvedOutput,
    )
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((lambdaArn, lambdaName, lambdaRoleId, resources)) => {
      open PulumiAws.PolicyDocument
      open ReventlessCore.Adapter

      // Console..log2(`CommandGeneratorResolvers_AppSync: Resources for ${name}:`, resources)

      let targetSqsResources =
        resources->ReventlessCore.Util.Adapter.filterSupportedResolvedResources([
          AWS.SQS.service,
          AWS.SQS_FIFO.service,
        ])

      let lambdaSqsSendPolicyDocument =
        targetSqsResources->Array.length > 0
          ? {
              Some(
                PulumiAws.PolicyDocument.make(
                  ~id=name ++ "SendSQS",
                  ~statements=[
                    {
                      sid: "LambdaAllowSendSQS",
                      effect: Allow,
                      actions: Action("sqs:SendMessage"),
                      resources: Resources(targetSqsResources->urns),
                    },
                  ],
                ),
              )
            }
          : None

      let _lambdaPolicy = {
        PulumiAws.IAM.RolePolicy.make(
          ~name,
          ~args={
            policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
              name ++ "LambdaPolicy",
              [
                Some(PulumiAws.Lambda.defaultLoggingPolicyDocument),
                lambdaSqsSendPolicyDocument,
              ]->Array.keepSome,
            )->Pulumi.Output.asInput,
            role: lambdaRoleId->Pulumi.Input.make,
          },
          ~opts,
        )
      }

      let _addCommandGeneratorPermission = PulumiAws.Lambda.Permission.make(
        ~name,
        ~args={
          action: "lambda:InvokeFunction",
          function: lambdaName->Pulumi.Input.make,
          principal: AWS.CloudwatchEventRule.principal,
        },
        ~opts,
      )

      let _attachDataSourcePolicy = PulumiAws.IAM.RolePolicy.make(
        ~name=name ++ "DataSource",
        ~args={
          PulumiAws.IAM.RolePolicy.policy: PulumiAws.PolicyDocument.make(
            ~id=name ++ "DataSourcePolicy",
            ~statements=[
              {
                sid: "AllowCloudWatchDataSourceInvokeLambda",
                effect: Allow,
                actions: Action("lambda:InvokeFunction"),
                resources: Resource(lambdaArn),
              },
            ],
          )
          ->toJsonString
          ->Pulumi.Input.make,
          role: dataSourceRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )
    })

  let dataSource = PulumiAws.AppSync.DataSource.make(
    ~name,
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

  let resolvers = fields->Array.map(field => {
    // Extract command name: last segment after splitting on "_".
    // Handles both old ("Aggregate_Command") and prefixed ("Plugin_Aggregate_Command") formats.
    let commandName = {
      let parts = field->String.split("_")
      parts->Array.get(parts->Array.length - 1)->Option.getOr(field)->String.capitalize
    }
    AppSync_Resolver_Retrying.makeUnitJsResolver(
      ~name=field->String.capitalize,
      ~api,
      ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
      ~type_="Mutation"->Pulumi.Input.make,
      ~field=field->Pulumi.Input.make,
      ~code=PulumiAws.AppSync.Resolver.Functions.invokeCommandGenerator(commandName),
      ~opts,
    )
  })

  // Source C: create Subscription.onX resolver for each mutation field.
  // @aws_subscribe in the SDL (emitted by Plugin_SubscriptionSchema) handles
  // delivery. AWS requires a dataSourceName even on UNIT subscription resolvers,
  // so we reuse the mutation's data source (its code never executes for subs).
  CommandSubscriptionResolvers_AppSync.make(
    ~api,
    ~mutationFields=fields,
    ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
    ~opts,
  )

  let resources = resolvers->Array.map(Util_AppSync.toResourceNative)

  {resources: resources}
}

// -- makeDcb (DCB StateChangeSlice mutations) --------------------------------
// Creates an AppSync DataSource + Resolver per DCB mutation field, pointing to
// the shared DCB CommandTopic Lambda. Unlike aggregate mutations, the TAG comes
// from the schema (not the field name), and there is no id: ID! parameter.
// The Lambda handler detects the CommandGenerator.payload format and runs
// makeGenerateCommand → publishJsons before returning the msgId.

let makeDcb = (
  ~api: api,
  ~runtime: ReventlessCore.Runtime.environment<runtimeParts>,
  ~fieldNames: array<string>,
  ~tags: array<string>,
  ~opts: Pulumi.ComponentResource.options,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda

  let dataSourceRole = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name="DcbMutationDS",
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
        ~name="DcbMutationDS",
        ~args={
          PulumiAws.IAM.RolePolicy.policy: PulumiAws.PolicyDocument.make(
            ~id="DcbMutationDSPolicy",
            ~statements=[
              {
                sid: "AllowDcbMutationInvokeLambda",
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
    ~name="DcbMutation",
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

  let _resolvers = Array.zip(fieldNames, tags)->Array.forEach(((fieldName, tag)) => {
    let _ = AppSync_Resolver_Retrying.makeUnitJsResolver(
      ~name=fieldName->String.capitalize,
      ~api,
      ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
      ~type_="Mutation"->Pulumi.Input.make,
      ~field=fieldName->Pulumi.Input.make,
      ~code=PulumiAws.AppSync.Resolver.Functions.invokeDcbMutation(tag),
      ~opts,
    )
  })

  // Source C: create Subscription.onX resolver for each DCB mutation field.
  CommandSubscriptionResolvers_AppSync.make(
    ~api,
    ~mutationFields=fieldNames,
    ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
    ~opts,
  )
}
