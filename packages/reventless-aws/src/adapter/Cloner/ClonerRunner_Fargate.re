open PulumiAws;

type api = Pulumi.Output.t(AppSync.GraphQLApi.t);

let make: Reventless.Cloner.Adapter.runnerMaker(api) =
  (
    ~name,
    ~api: api,
    ~fullQualifiedStackName,
    ~reventlessCiSecretUrn,
    ~secretUrns,
    ~opts=?,
    (),
  ) => {
    let cluster = ECS.Cluster.(make(~name, ~opts?, ()));

    let taskExecutionRole =
      IAM.Role.make(
        ~name=name ++ "TaskExecution",
        ~args=
          IAM.Role.Args.make(
            ~assumeRolePolicy=
              IAM.Policy.assumeRolePolicy("ecs-tasks.amazonaws.com")
              ->Pulumi.Input.wrap,
            ~inlinePolicies=
              [|
                IAM.InlinePolicy.makeForActions(
                  ~name="clonerTask",
                  ~actions=[|
                    "logs:PutLogEvents",
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                  |],
                ),
              |]
              ->Pulumi.Input.wrap,
            (),
          ),
        (),
      );

    let secretsManagerAccessPolicy =
      IAM.Policy.makeForActions(
        ~name="secretsManagerAccess",
        ~actions=[|
          "secretsmanager:GetRandomPassword",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        |],
      );

    let taskRunnerPolicy =
      IAM.Policy.makeForActions(
        ~name="taskRunner",
        ~actions=[|"ecs:RunTask", "iam:PassRole"|],
      );

    let _ =
      IAM.RolePolicyAttachment.(
        make(
          ~name="ClonerTaskExecutionSecretsManagerAccess",
          ~args=
            Args.make(
              ~policyArn=
                secretsManagerAccessPolicy##arn->Pulumi.Output.asInput,
              ~role=taskExecutionRole##name->Pulumi.Output.asInput,
            ),
          ~opts,
        )
      );

    let vpcStackName =
      Pulumi.Config.make(Some("vpc"))
      ->Pulumi.Config.get("stack")
      ->Belt.Option.getExn;
    let vpcConfig =
      Reventless.Util.VPC.getVpcConfig(
        ~stackName=vpcStackName,
        ~outputName="vpc",
      );

    let secrets =
      secretUrns
      ->Belt.Array.map(urn =>
          PulumiAws.GetSecretVersion.getSecretNames(urn)
          ->Pulumi.Output.apply(names =>
              names->Belt.Array.map(name =>
                ECS.Container.Secret.make(
                  ~name,
                  ~valueFrom={j|$urn:$name::|j},
                )
              )
            )
        )
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(Belt.Array.concatMany);

    let resources =
      (
        secretsManagerAccessPolicy##arn,
        taskRunnerPolicy##arn,
        vpcConfig,
        secrets,
      )
      ->Pulumi.Output.all4
      ->Pulumi.Output.apply(
          (
            (
              secretsManagerAccessPolicyArn,
              taskRunnerPolicyArn,
              vpcConfig,
              secrets,
            ),
          ) => {
          let containerDefinitions =
            [|
              ECS.Container.(
                ContainerDefinition.make(
                  ~name="reventless-ci",
                  ~image=
                    Pulumi.Config.make(Some("ci"))
                    ->Pulumi.Config.require("image"),
                  ~memory=512,
                  ~repositoryCredentials=
                    RepositoryCredentials.make(
                      ~credentialsParameter=reventlessCiSecretUrn,
                    ),
                  ~secrets,
                  ~logConfiguration=
                    LogConfiguration.make(
                      ~logDriver="awslogs",
                      ~options=
                        [|("awslogs-create-group", "true")|]
                        ->Js.Dict.fromArray,
                      (),
                    ),
                )
              ),
            |]
            ->Js.Json.stringifyAny
            ->Belt.Option.getExn;

          let taskDefinition =
            ECS.TaskDefinition.(
              make(
                ~name,
                ~args=
                  Args.make(
                    ~family=name->Pulumi.Input.wrap,
                    ~containerDefinitions=
                      containerDefinitions->Pulumi.Input.wrap,
                    ~executionRoleArn=
                      taskExecutionRole##arn->Pulumi.Output.asInput,
                    ~memory="512"->Pulumi.Input.wrap,
                    ~cpu="256"->Pulumi.Input.wrap,
                    ~requiresCompatibilities=[|"FARGATE"|],
                    ~networkMode=`awsvpc,
                    (),
                  ),
                ~opts?,
                (),
              )
            );

          let lambda =
            Lambda.CallbackFunction.make(
              ~name,
              ~args=
                Lambda.CallbackFunction.Args.make(
                  ~policies=[|
                    secretsManagerAccessPolicyArn,
                    taskRunnerPolicyArn,
                    PulumiAws.Lambda.Policy.awsLambdaFullAccess,
                  |],
                  ~callback=
                    ClonerRunner_Fargate_Runtime.clone(
                      ~taskDefinition=taskDefinition##arn,
                      ~cluster=cluster##arn,
                      ~fullQualifiedStackName,
                      ~subnets=vpcConfig##subnetIds,
                    ),
                  (),
                ),
              ~opts?,
              (),
            );

          let _lambdaPermission =
            Lambda.Permission.make(
              ~name,
              ~args=
                Lambda.Permission.Args.make(
                  ~action="lambda:InvokeFunction",
                  ~_function=lambda##arn->Pulumi.Output.asInput,
                  ~principal="appsync.amazonaws.com",
                  (),
                ),
              ~opts?,
              (),
            );

          let dataSourceRole =
            IAM.Role.makeWithDefaultPolicy(
              ~name=name ++ "DS",
              ~service="appsync.amazonaws.com"->Pulumi.Output.make,
              ~opts?,
              (),
            );

          let _dataSourcePolicy =
            IAM.RolePolicy.make(
              ~name=name ++ "DS",
              ~action="lambda:InvokeFunction",
              ~resource=[|lambda##arn|],
              ~role=dataSourceRole##id,
              ~opts?,
              (),
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
                      ~functionArn=lambda##arn->Pulumi.Output.asInput,
                      (),
                    )
                    ->Pulumi.Input.wrap,
                  ~serviceRoleArn=dataSourceRole##arn->Pulumi.Output.asInput,
                  (),
                ),
              ~opts,
            );

          let invokeClone = {j|{
            "version": "2017-02-28",
            "operation": "Invoke",
            "payload": {
                "pointInTime": \$utils.toJson(\$context.arguments.pointInTime),
                "meta": {
                  "ip": \$util.toJson(\$context.identity.sourceIp),
                  "user": \$util.toJson(\$context.identity.username)
                }
            }
          }
          |j};

          let field = "clone";
          let resolver =
            AppSync.Resolver.make(
              ~name=field,
              ~api,
              ~dataSourceName=dataSource##name->Pulumi.Output.asInput,
              ~_type="Mutation"->Pulumi.Input.wrap,
              ~field=field->Pulumi.Input.wrap,
              ~requestTemplate=invokeClone->Pulumi.Input.wrap,
              ~responseTemplate=
                AppSync.Resolver.Templates.result->Pulumi.Input.wrap,
              ~kind=AppSync.Resolver.Unit,
              ~opts?,
              (),
            );

          [|resolver->Util_AppSync.toResource|];
        });

    {resources: resources};
  };
