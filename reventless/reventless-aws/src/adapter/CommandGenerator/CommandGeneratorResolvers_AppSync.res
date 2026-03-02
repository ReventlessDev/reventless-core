type api = Types.AppSync.api
type runtimeParts = Util.Lambda.runtimeParts

let handleResolversEvent = (generateCommand: ReventlessCore.CommandGenerator.commandGenerator) =>
  Pulumi.Output.make((event, _context) => event->generateCommand)

let make: ReventlessCore.CommandGenerator_Adapter.resolversMaker<api, Util.Lambda.runtimeParts> = (
  ~name: string,
  ~api: api,
  ~fields,
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

  let invokeCommandGenerator = command =>
    `
  #set($parentTypeName = $context.info.parentTypeName)
  #set($fieldName = $context.info.fieldName)
  {
    "version": "2017-02-28",
    "operation": "Invoke",
    "payload": {
        "command": "${command}",
        "arguments": $utils.toJson($context.arguments),
        "meta": {
          "ip": $util.toJson($context.identity.sourceIp),
          "user": $util.toJson($context.identity.username),
          "info": $util.toJson("$parentTypeName.$fieldName")
        }
    }
  }
  `->Pulumi.Input.make

  let resolvers = fields->Array.map(field => {
    let commandName = switch field->String.split("_") {
    | [_aggregate, commandName] => commandName->String.capitalize
    | _ => field->String.capitalize
    }
    PulumiAws.AppSync.Resolver.makeUnitResolver(
      ~name=field->String.capitalize,
      ~api,
      ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
      ~type_="Mutation"->Pulumi.Input.make,
      ~field=field->Pulumi.Input.make,
      ~requestTemplate=invokeCommandGenerator(commandName),
      ~responseTemplate=PulumiAws.AppSync.Resolver.Templates.result,
      ~opts,
    )
  })

  let resources = resolvers->Array.map(Util_AppSync.toResource)

  {resources: resources}
}
