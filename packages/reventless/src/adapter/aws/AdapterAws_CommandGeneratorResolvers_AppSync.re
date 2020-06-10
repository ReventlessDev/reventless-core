open PulumiAws;

type api = AppSync.GraphQLApi.t;

let make =
    (
      ~name: string,
      ~api,
      ~fields,
      ~commandGenerator: CommandGenerator.commandGenerator,
      ~opts: Pulumi.CustomResourceOptions.t,
    ) => {
  let commandGeneratorLambda =
    Lambda.CallbackFunction.make(
      ~name,
      ~args=
        Lambda.CallbackFunction.Args.make(
          ~callback=
            AdapterAws_CommandGeneratorResolvers_AppSync_Runtime.generateCommand(
              commandGenerator,
            ),
          ~tracingConfig=
            Lambda.CallbackFunction.Args.TracingConfig.make(~mode=`Active),
          (),
        ),
      ~opts,
      (),
    );

  let commandGeneratorArn = commandGeneratorLambda##arn;

  let _commandGeneratorPermission =
    Lambda.Permission.make(
      ~name=name ++ "Permission",
      ~args=
        Lambda.Permission.Args.make(
          ~action="lambda:InvokeFunction",
          ~_function=commandGeneratorArn->Pulumi.Output.asInput,
          ~principal="appsync.amazonaws.com",
          (),
        ),
      ~opts,
      (),
    );

  let dataSourceRole =
    IAM.Role.makeWithDefaultPolicy(
      ~name=name ++ "DataSourceRole",
      ~service="appsync.amazonaws.com",
      ~opts,
      (),
    );

  let _dataSourcePolicy =
    IAM.RolePolicy.make(
      ~name=name ++ "DataSourceRolePolicy",
      ~action="lambda:InvokeFunction",
      ~resource=[|commandGeneratorArn|],
      ~role=dataSourceRole##id,
      ~opts,
      (),
    );

  let dataSource =
    AppSync.DataSource.make(
      ~name=name ++ "DataSource",
      ~args=
        AppSync.DataSource.Args.make(
          ~_type=`AWS_LAMBDA,
          ~apiId=api##id->Pulumi.Output.asInput,
          ~lambdaConfig=
            AppSync.DataSource.LambdaConfig.make(
              ~functionArn=commandGeneratorArn->Pulumi.Output.asInput,
              (),
            ),
          ~name=name ++ "DataSource", // This has to be provided for DataSource !
          ~serviceRoleArn=dataSourceRole##arn->Pulumi.Output.asInput,
          (),
        ),
      ~opts=Some(opts),
    );

  let invokeCommandGenerator = command => {j|
    {
      "version": "2017-02-28",
      "operation": "Invoke",
      "payload": {
          "command": "$command",
          "arguments": \$utils.toJson(\$context.arguments),
          "meta": {
            "ip": \$util.toJson(\$context.identity.sourceIp),
            "user": \$util.toJson(\$context.identity.username)
          }
      }
    }
  |j};

  let resolvers =
    fields
    |> Array.map(field => {
         let commandName = field->String.capitalize;
         AppSync.Resolver.make(
           ~name=commandName ++ "CommandResolver",
           ~api,
           ~dataSourceName=dataSource##name->Pulumi.Output.asInput,
           ~_type="Mutation",
           ~field,
           ~requestTemplate=
             invokeCommandGenerator(commandName)->Pulumi.Input.wrap,
           ~responseTemplate=
             AppSync.Resolver.Templates.result->Pulumi.Input.wrap,
           ~kind=AppSync.Resolver.Unit,
           ~opts,
           (),
         );
       });

  let resources = resolvers |> Array.map(AdapterAws_Util_AppSync.toResource);

  {CommandGenerator.resources: resources};
};