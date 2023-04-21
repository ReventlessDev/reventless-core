open PulumiAws

type api = Pulumi.Output.t<AppSync.GraphQLApi.t>

let make: Reventless.Cloner.Adapter.runnerMaker<api> = (
  ~name,
  ~api: api,
  ~fullQualifiedStackName,
  ~reventlessCiSecretUrn,
  ~secretUrns,
  ~opts=?,
  (),
) => {
  let cluster = {
    open ECS.Cluster
    make(~name, ~opts?, ())
  }

  let taskExecutionRole = IAM.Role.make(
    ~name=name ++ "TaskExecution",
    ~args=IAM.Role.Args.make(
      ~assumeRolePolicy=IAM.Policy.assumeRolePolicy("ecs-tasks.amazonaws.com")->Pulumi.Input.make,
      ~inlinePolicies=[
        IAM.InlinePolicy.makeForActions(
          ~name="clonerTask",
          ~actions=["logs:PutLogEvents", "logs:CreateLogGroup", "logs:CreateLogStream"],
        ),
      ]->Pulumi.Input.make,
      (),
    ),
    (),
  )

  let secretsManagerAccessPolicy = IAM.Policy.makeForActions(
    ~name="secretsManagerAccess",
    ~actions=[
      "secretsmanager:GetRandomPassword",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ],
  )

  let taskRunnerPolicy = IAM.Policy.makeForActions(
    ~name="taskRunner",
    ~actions=["ecs:RunTask", "iam:PassRole"],
  )

  let _ = {
    open IAM.RolePolicyAttachment
    make(
      ~name="ClonerTaskExecutionSecretsManagerAccess",
      ~args=Args.make(
        ~policyArn=secretsManagerAccessPolicy["arn"]->Pulumi.Output.asInput,
        ~role=taskExecutionRole["name"]->Pulumi.Output.asInput,
      ),
      ~opts,
    )
  }

  let vpcStackName = Pulumi.Config.make(Some("vpc"))->Pulumi.Config.get("stack")->Belt.Option.getExn
  let vpcConfig = Reventless.Util.VPC.getVpcConfig(~stackName=vpcStackName, ~outputName="vpc")

  let secrets =
    secretUrns
    ->Belt.Array.map(urn =>
      PulumiAws.GetSecretVersion.getSecretNames(urn)->Pulumi.Output.apply(names =>
        names->Belt.Array.map(
          name => ECS.Container.Secret.make(~name, ~valueFrom=`${urn}:${name}::`),
        )
      )
    )
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(Belt.Array.concatMany)

  let resources =
    (secretsManagerAccessPolicy["arn"], taskRunnerPolicy["arn"], vpcConfig, secrets)
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((
      secretsManagerAccessPolicyArn,
      taskRunnerPolicyArn,
      vpcConfig,
      secrets,
    )) => {
      let containerDefinitions = [
        {
          open ECS.Container
          ContainerDefinition.make(
            ~name="reventless-ci",
            ~image=Pulumi.Config.make(Some("ci"))->Pulumi.Config.require("image"),
            ~cpu=1024,
            ~memory=4096,
            ~repositoryCredentials=RepositoryCredentials.make(
              ~credentialsParameter=reventlessCiSecretUrn,
            ),
            ~secrets,
            ~logConfiguration=LogConfiguration.make(
              ~logDriver="awslogs",
              ~options={
                "awslogs-create-group": "true",
                "awslogs-group": "/aws/ecs/reventless-cloner",
                "awslogs-region": Pulumi.Config.make(Some("aws"))->Pulumi.Config.require("region"),
                "awslogs-stream-prefix": "reventless-cloner",
              },
              (),
            ),
            ~ulimits=[
              ContainerDefinition.Ulimit.make(
                ~name=#nofile,
                ~hardLimit=1048576,
                ~softLimit=1048576,
              ),
            ],
            (),
          )
        },
      ]

      let taskDefinition = {
        open ECS.TaskDefinition
        make(
          ~name,
          ~args=Args.make(
            ~family=name->Pulumi.Input.make,
            ~containerDefinitions=containerDefinitions
            ->Js.Json.stringifyAny
            ->Belt.Option.getExn
            ->Pulumi.Input.make,
            ~executionRoleArn=taskExecutionRole["arn"]->Pulumi.Output.asInput,
            ~memory="4096"->Pulumi.Input.make,
            ~cpu="1024"->Pulumi.Input.make,
            ~requiresCompatibilities=["FARGATE"],
            ~networkMode=#awsvpc,
            (),
          ),
          ~opts?,
          (),
        )
      }

      let lambda = Lambda.CallbackFunction.make(
        ~name,
        ~args=Lambda.CallbackFunction.Args.make(
          ~policies=[
            secretsManagerAccessPolicyArn,
            taskRunnerPolicyArn,
            PulumiAws.IAM.ManagedPolicies.lambdaFullAccess,
          ],
          ~callback=ClonerRunner_Fargate_Runtime.clone(
            ~taskDefinition=taskDefinition["arn"],
            ~cluster=cluster["arn"],
            ~fullQualifiedStackName,
            ~subnets=vpcConfig["subnetIds"],
          ),
          (),
        ),
        ~opts?,
        (),
      )

      let _lambdaPermission = Lambda.Permission.make(
        ~name,
        ~args=Lambda.Permission.Args.make(
          ~action="lambda:InvokeFunction",
          ~_function=lambda["arn"]->Pulumi.Output.asInput,
          ~principal="appsync.amazonaws.com",
          (),
        ),
        ~opts?,
        (),
      )

      let dataSourceRole = IAM.Role.makeWithDefaultPolicy(
        ~name=name ++ "DS",
        ~service="appsync.amazonaws.com"->Pulumi.Output.make,
        ~opts?,
        (),
      )

      let _dataSourcePolicy = {
        open IAM
        RolePolicy.make(
          ~name=name ++ "DS",
          ~args=RolePolicy.Args.make(
            ~policy=lambda["arn"]
            ->Pulumi.Output.apply(lambdaArn =>
              RolePolicy.generatePolicy([lambdaArn], "lambda:InvokeFunction")
            )
            ->Pulumi.Output.asInput,
            ~role=dataSourceRole["id"]->Pulumi.Output.asInput,
            (),
          ),
          ~opts?,
          (),
        )
      }

      let dataSource = AppSync.DataSource.make(
        ~name,
        ~args=AppSync.DataSource.Args.make(
          ~_type=#AWS_LAMBDA,
          ~apiId=api->Pulumi.Output.flatMap(api => api["id"])->Pulumi.Output.asInput,
          ~lambdaConfig=AppSync.DataSource.LambdaConfig.make(
            ~functionArn=lambda["arn"]->Pulumi.Output.asInput,
            (),
          )->Pulumi.Input.make,
          ~serviceRoleArn=dataSourceRole["arn"]->Pulumi.Output.asInput,
          (),
        ),
        ~opts,
      )

      let invokeClone = `{
            "version": "2017-02-28",
            "operation": "Invoke",
            "payload": {
                "restoreDateTime": $utils.toJson($context.arguments.restoreDateTime),
                "meta": {
                  "ip": $util.toJson($context.identity.sourceIp),
                  "user": $util.toJson($context.identity.username)
                }
            }
          }
          `

      let field = "clone"
      let resolver = AppSync.Resolver.makeUnitResolver(
        ~name=field,
        ~api,
        ~dataSourceName=dataSource["name"]->Pulumi.Output.asInput,
        ~_type="Mutation"->Pulumi.Input.make,
        ~field=field->Pulumi.Input.make,
        ~requestTemplate=invokeClone->Pulumi.Input.make,
        ~responseTemplate=AppSync.Resolver.Templates.result,
        ~opts?,
        (),
      )

      [resolver->Util_AppSync.toResource]
    })

  {resources: resources}
}
