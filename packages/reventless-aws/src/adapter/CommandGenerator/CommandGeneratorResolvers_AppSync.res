type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>
type runtimeParts = Util.Lambda.runtimeParts

let makeHandler = (generateCommand: Reventless.CommandGenerator.commandGenerator) =>
  Pulumi.Output.make((event, _) => event->generateCommand)

let make: Reventless.CommandGenerator_Adapter.resolversMaker<api, Util.Lambda.runtimeParts> = (
  ~name: string,
  ~api: api,
  ~fields,
  ~runtime,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let _addCommandGeneratorPermissions = {
    let _commandGeneratorPolicy = {
      open PulumiAws
      PulumiAws.IAM.RolePolicy.make(
        ~name=name ++ "CommandGeneratorPolicy",
        ~args={
          policy: PulumiAws.Lambda.defaultLoggingPolicyDocument
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )
    }

    let _addCommandGeneratorPermission = PulumiAws.Lambda.Permission.make(
      ~name=name ++ "Permission",
      ~args={
        action: "lambda:InvokeFunction",
        function: lambda.arn->Pulumi.Output.asInput,
        principal: AWS.CloudwatchEventRule.principal,
      },
      ~opts,
    )
  }

  let dataSourceRole = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "DataSource",
    ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
    ~opts,
  )

  let _attachDataSourcePolicy = lambda.arn->Pulumi.Output.apply(commandGeneratorArn => {
    open PulumiAws.PolicyDocument
    PulumiAws.IAM.RolePolicy.make(
      ~name=name ++ "DataSourcePolicy",
      ~args={
        PulumiAws.IAM.RolePolicy.policy: PulumiAws.PolicyDocument.make(
          ~id=name ++ "DataSourcePolicy",
          ~statements=[
            {
              sid: "AllowCloudWatchDataSourceInvokeLambda",
              effect: Allow,
              actions: Action("lambda:InvokeFunction"),
              resources: Resource(commandGeneratorArn),
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
        PulumiAws.AppSync.DataSource.functionArn: lambda.arn->Pulumi.Output.asInput,
      }->Pulumi.Input.make,
      serviceRoleArn: dataSourceRole.arn->Pulumi.Output.asInput,
    },
    ~opts=Some(opts),
  )

  let invokeCommandGenerator = command =>
    `
      {
        "version": "2017-02-28",
        "operation": "Invoke",
        "payload": {
            "command": "${command}",
            "arguments": $utils.toJson($context.arguments),
            "meta": {
              "ip": $util.toJson($context.identity.sourceIp),
              "user": $util.toJson($context.identity.username)
            }
        }
      }
      `->Pulumi.Input.make

  let resolvers = fields->Belt.Array.map(field => {
    let commandName = switch field->Js.String2.split("_") {
    | [_aggregate, commandName] => commandName->StringLabels.capitalize_ascii
    | _ => field->StringLabels.capitalize_ascii
    }
    PulumiAws.AppSync.Resolver.makeUnitResolver(
      ~name=field->StringLabels.capitalize_ascii,
      ~api,
      ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
      ~type_="Mutation"->Pulumi.Input.make,
      ~field=field->Pulumi.Input.make,
      ~requestTemplate=invokeCommandGenerator(commandName),
      ~responseTemplate=PulumiAws.AppSync.Resolver.Templates.result,
      ~opts,
    )
  })

  let resources = resolvers->Belt.Array.map(Util_AppSync.toResource)

  {resources: resources}
}
