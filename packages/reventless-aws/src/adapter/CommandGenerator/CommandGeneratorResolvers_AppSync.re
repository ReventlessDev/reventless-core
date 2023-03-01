open PulumiAws;

type api = Pulumi.Output.t(AppSync.GraphQLApi.t);

let make: Reventless.CommandGenerator.Adapter.resolversMaker(api) =
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
        ~name=name ++ "DS",
        ~service="appsync.amazonaws.com"->Pulumi.Output.make,
        ~opts,
        (),
      );

    let _dataSourcePolicy =
      IAM.(
        RolePolicy.make(
          ~name=name ++ "DS",
          ~args=
            RolePolicy.Args.make(
              ~policy=
                commandGeneratorArn
                ->Pulumi.Output.apply(commandGeneratorArn =>
                    RolePolicy.generatePolicy(
                      [|commandGeneratorArn|],
                      "lambda:InvokeFunction",
                    )
                  )
                ->Pulumi.Output.asInput,
              ~role=dataSourceRole##id->Pulumi.Output.asInput,
              (),
            ),
          ~opts,
          (),
        )
      );

    let dataSource =
      AppSync.DataSource.make(
        ~name,
        ~args=
          AppSync.DataSource.Args.make(
            ~_type=`AWS_LAMBDA,
            ~apiId=
              api
              ->Pulumi.Output.flatMap(api => api##id)
              ->Pulumi.Output.asInput,
            ~lambdaConfig=
              AppSync.DataSource.LambdaConfig.make(
                ~functionArn=commandGeneratorArn->Pulumi.Output.asInput,
                (),
              )
              ->Pulumi.Input.make,
            ~serviceRoleArn=dataSourceRole##arn->Pulumi.Output.asInput,
            (),
          ),
        ~opts=Some(opts),
      );

    let invokeCommandGenerator = command =>
      {j|
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
      |j}
      ->Pulumi.Input.make;

    let resolvers =
      fields->Belt.Array.map(field => {
        let commandName =
          switch (field->Js.String2.split("_")) {
          | [|_aggregate, commandName|] =>
            commandName->String.capitalize_ascii
          | _ => field->String.capitalize_ascii
          };
        let _log =
          dataSource##name
          ->Pulumi.Output.apply(dsn =>
              Js.log2(
                "COMMANDGEN-RESOLVER " ++ name ++ "DATASOURCENAME:",
                dsn,
              )
            );
        AppSync.Resolver.makeUnitResolver(
          ~name=field->String.capitalize_ascii,
          ~api,
          ~dataSourceName=dataSource##name->Pulumi.Output.asInput,
          ~_type="Mutation"->Pulumi.Input.make,
          ~field=field->Pulumi.Input.make,
          ~requestTemplate=invokeCommandGenerator(commandName),
          ~responseTemplate=AppSync.Resolver.Templates.result,
          ~opts,
          (),
        );
      });

    let resources = resolvers->Belt.Array.map(Util_AppSync.toResource);

    {resources: resources};
  };
