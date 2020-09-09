open PulumiAws;

type api = Pulumi.Output.t(AppSync.GraphQLApi.t);

let make =
    (
      ~name: string,
      ~api: api,
      ~fields,
      ~commandGenerator: Reventless.CommandGenerator.commandGenerator,
      ~opts: Pulumi.CustomResourceOptions.t,
    ) => {
  let commandGeneratorLambda =
    Lambda.CallbackFunction.make(
      ~name,
      ~args=
        Lambda.CallbackFunction.Args.make(
          ~callback=
            CommandGeneratorResolvers_AppSync_Runtime.generateCommand(
              commandGenerator,
            ),
          ~tracingConfig=
            Lambda.CallbackFunction.Args.TracingConfig.make(~mode=`Active)
            ->Pulumi.Input.wrap,
          (),
        ),
      ~opts,
      (),
    );

  let commandGeneratorArn = commandGeneratorLambda##arn;

  let _commandGeneratorPermission =
    Lambda.Permission.make(
      ~name,
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
      ~name=name ++ "DataSource",
      ~service="appsync.amazonaws.com"->Pulumi.Output.make,
      ~opts,
      (),
    );

  let _dataSourcePolicy =
    IAM.RolePolicy.make(
      ~name=name ++ "DataSource",
      ~action="lambda:InvokeFunction",
      ~resource=[|commandGeneratorArn|],
      ~role=dataSourceRole##id,
      ~opts,
      (),
    );

  let dataSource =
    AppSync.DataSource.make(
      ~name,
      ~args=
        AppSync.DataSource.Args.make(
          ~_type=`AWS_LAMBDA,
          ~apiId=
            api->Pulumi.Output.flatMap(api => api##id)->Pulumi.Output.asInput,
          ~lambdaConfig=
            AppSync.DataSource.LambdaConfig.make(
              ~functionArn=commandGeneratorArn->Pulumi.Output.asInput,
              (),
            )
            ->Pulumi.Input.wrap,
          ~name=name->Pulumi.Input.wrap, // This has to be provided for DataSource !
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
           ~name=commandName,
           ~api,
           ~dataSourceName=dataSource##name->Pulumi.Output.asInput,
           ~_type="Mutation"->Pulumi.Input.wrap,
           ~field=field->Pulumi.Input.wrap,
           ~requestTemplate=
             invokeCommandGenerator(commandName)->Pulumi.Input.wrap,
           ~responseTemplate=
             AppSync.Resolver.Templates.result->Pulumi.Input.wrap,
           ~kind=AppSync.Resolver.Unit,
           ~opts,
           (),
         );
       });

  let resources = resolvers |> Array.map(Util_AppSync.toResource);

  {Reventless.CommandGenerator.resources: resources};
};
