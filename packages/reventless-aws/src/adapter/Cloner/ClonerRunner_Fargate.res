open PulumiAws

type api = Pulumi.Output.t<AppSync.GraphQLApi.t>

let make: Reventless.Cloner.Adapter.runnerMaker<api> = (
  ~name,
  ~api: api,
  ~fullQualifiedStackName,
  ~reventlessCiSecretUrn,
  ~secretUrns,
  ~opts=?,
) => {
  let cluster = {
    open ECS.Cluster
    make(~name, ~opts?)
  }

  let taskExecutionRole = IAM.Role.make(
    ~name=name ++ "TaskExecution",
    ~args={
      IAM.Role.assumeRolePolicy: IAM.Policy.assumeRolePolicy(
        name,
        "ecs-tasks.amazonaws.com",
      )->Pulumi.Input.make,
      inlinePolicies: [
        IAM.InlinePolicy.makeForActions(
          ~name="clonerTask",
          ~actions=["logs:PutLogEvents", "logs:CreateLogGroup", "logs:CreateLogStream"],
        ),
      ]->Pulumi.Input.make,
    },
  )

  let secretsManagerPolicyDocument = PolicyDocument.make(
    ~id=name ++ "SecretsManagerPolicy",
    ~statements=[
      {
        sid: "AllowManageSecrets",
        effect: PolicyDocument.Allow,
        actions: PolicyDocument.Actions([
          "secretsmanager:GetRandomPassword",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]),
      },
    ],
  )

  let secretsManagerAccessPolicy = IAM.Policy.make(
    ~name="secretsManagerAccess",
    ~args={
      policy: secretsManagerPolicyDocument
      ->PolicyDocument.toJsonString
      ->Pulumi.Input.make,
    },
  )

  let taskRunnerPolicyDocument = PolicyDocument.make(
    ~id=name ++ "TaskRunnerPolicy",
    ~statements=[
      {
        sid: "AllowRunTask",
        effect: PolicyDocument.Allow,
        actions: PolicyDocument.Actions(["ecs:RunTask", "iam:PassRole"]),
      },
    ],
  )

  let taskRunnerPolicy = IAM.Policy.make(
    ~name="taskRunner",
    ~args={
      policy: taskRunnerPolicyDocument
      ->PolicyDocument.toJsonString
      ->Pulumi.Input.make,
    },
  )

  let _ = {
    open IAM.RolePolicyAttachment
    make(
      ~name="ClonerTaskExecutionSecretsManagerAccess",
      ~args={
        policyArn: secretsManagerAccessPolicy.arn->Pulumi.Output.asInput,
        role: taskExecutionRole.id->Pulumi.Output.asInput,
      },
      ~opts,
    )
  }

  let vpcStackName = Pulumi.Config.make(Some("vpc"))->Pulumi.Config.get("stack")->Belt.Option.getExn
  let vpcConfig = Reventless.Util.VPC.getVpcConfig(~stackName=vpcStackName, ~outputName="vpc")

  let secrets =
    secretUrns
    ->Belt.Array.map(urn =>
      PulumiAws.GetSecretVersion.getSecretNames(urn)->Pulumi.Output.apply(names =>
        names->Belt.Array.map(name => {ECS.Container.name, valueFrom: `${urn}:${name}::`})
      )
    )
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(s => Belt.Array.concatMany(s))

  let resources =
    (secretsManagerAccessPolicy.arn, taskRunnerPolicy.arn, vpcConfig, secrets)
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((
      secretsManagerAccessPolicyArn,
      taskRunnerPolicyArn,
      vpcConfig,
      secrets,
    )) => {
      let containerDefinitions = [
        {
          ECS.Container.name: "reventless-ci",
          image: Pulumi.Config.make(Some("ci"))->Pulumi.Config.require("image"),
          cpu: 1024,
          memory: 4096,
          repositoryCredentials: {credentialsParameter: reventlessCiSecretUrn},
          secrets,
          logConfiguration: {
            logDriver: "awslogs",
            options: {
              awslogsCreateGroup: true,
              awslogsGroup: "/aws/ecs/reventless-cloner",
              awslogsRegion: Pulumi.Config.make(Some("aws"))->Pulumi.Config.require("region"),
              awslogsStreamPrefix: "reventless-cloner",
            },
          },
          ulimits: [
            {
              name: #nofile,
              hardLimit: 1048576,
              softLimit: 1048576,
            },
          ],
        },
      ]

      let taskDefinition = ECS.TaskDefinition.make(
        ~name,
        ~args={
          family: name->Pulumi.Input.make,
          containerDefinitions: containerDefinitions
          ->Js.Json.stringifyAny
          ->Belt.Option.getExn
          ->Pulumi.Input.make,
          executionRoleArn: taskExecutionRole.arn->Pulumi.Output.asInput,
          memory: "4096"->Pulumi.Input.make,
          cpu: "1024"->Pulumi.Input.make,
          requiresCompatibilities: ["FARGATE"],
          networkMode: #awsvpc,
        },
        ~opts?,
      )

      let lambdaRole = PulumiAws.IAM.Role.makeWithDefaultPolicy(
        ~name,
        ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
        ~opts?
      )

      let lambda = Lambda.CallbackFunction.make(
        ~name,
        ~args=Lambda.CallbackFunction.Args.make(
          ~callback=ClonerRunner_Fargate_Runtime.clone(
            ~taskDefinition=taskDefinition.arn,
            ~cluster=cluster.arn,
            ~fullQualifiedStackName,
            ~subnets={subnets: vpcConfig.subnetIds},
            ...
          )
        ),
        ~opts?,
      )
      let _ = lambda.arn->Pulumi.Output.apply(arn => {
        let appsyncInvokeLambdaPolicyDocument = PulumiAws.PolicyDocument.make(
          ~id=name ++ "AppSyncInvokePolicy",
          ~statements=[
            {
              sid: "AllowAppSyncInvoke",
              effect: PulumiAws.PolicyDocument.Allow,
              actions: PulumiAws.PolicyDocument.Action("lambda:InvokeFunction"),
              resources: PulumiAws.PolicyDocument.Resource(arn),
              principal: PulumiAws.PolicyDocument.Principals({
                service: PulumiAws.PolicyDocument.PrincipalId(AWS.AppSync.principal),
              }),
            },
          ],
        )

        let lambdaPolicyDocument = PulumiAws.PolicyDocument.mergePolicyDocuments(
          name ++ "LambdaPolicy",
          [
            PulumiAws.Lambda.defaultLoggingPolicyDocument,
            appsyncInvokeLambdaPolicyDocument,
            secretsManagerPolicyDocument,
            taskRunnerPolicyDocument,
          ],
        )

        lambdaRole.id->Pulumi.Output.apply(
          lambdaRoleId => {
            let _lambdaRolePolicy = PulumiAws.IAM.RolePolicy.make(
              ~name=name ++ "LambdaRolePolicy",
              ~args={
                policy: lambdaPolicyDocument
                ->Pulumi.Output.apply(lambdaPolicyDocument => lambdaPolicyDocument)
                ->Pulumi.Output.asInput,
                role: lambdaRoleId->Pulumi.Input.make,
              },
            )
          },
        )
      })

      let dataSourceRole = IAM.Role.makeWithDefaultPolicy(
        ~name=name ++ "DS",
        ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
        ~opts?,
      )

      let _dataSourcePolicy = {
        open IAM
        RolePolicy.make(
          ~name=name ++ "DS",
          ~args={
            policy: lambda.arn
            ->Pulumi.Output.apply(lambdaArn =>
              //RolePolicy.generatePolicy([lambdaArn], "lambda:InvokeFunction")
              PolicyDocument.make(
                ~id=name ++ "LambdaPolicy",
                ~statements=[
                  {
                    sid: "AllowInvokeLambda",
                    effect: PolicyDocument.Allow,
                    actions: PolicyDocument.Action("lambda:InvokeFunction"),
                    resources: PolicyDocument.Resource(lambdaArn),
                  },
                ],
              )->PolicyDocument.toJsonString
            )
            ->Pulumi.Output.asInput,
            role: dataSourceRole.id->Pulumi.Output.asInput,
          },
          ~opts?,
        )
      }

      let dataSource = AppSync.DataSource.make(
        ~name,
        ~args={
          AppSync.DataSource.type_: AWS_LAMBDA,
          apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
          lambdaConfig: {
            AppSync.DataSource.functionArn: lambda.arn->Pulumi.Output.asInput,
          }->Pulumi.Input.make,
          serviceRoleArn: dataSourceRole.arn->Pulumi.Output.asInput,
        },
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
        ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
        ~type_="Mutation"->Pulumi.Input.make,
        ~field=field->Pulumi.Input.make,
        ~requestTemplate=invokeClone->Pulumi.Input.make,
        ~responseTemplate=AppSync.Resolver.Templates.result,
        ~opts?,
      )

      [resolver->Util_AppSync.toResource]
    })

  {resources: resources}
}
