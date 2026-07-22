open PulumiAws

type api = Types.AppSync.api

let make: ReventlessCore.Cloner.Adapter.runnerMaker<api> = (
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
      tags: AWS.Tags.make(
        ~name=name ++ "TaskExecution",
        ~kind=ReventlessCore.Cloner.componentType,
        ~role=Identity,
        ~component=name,
      ),
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
      tags: AWS.Tags.make(
        ~name="secretsManagerAccess",
        ~kind=ReventlessCore.Cloner.componentType,
        ~role=Identity,
        ~component=name,
      ),
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
      tags: AWS.Tags.make(
        ~name="taskRunner",
        ~kind=ReventlessCore.Cloner.componentType,
        ~role=Identity,
        ~component=name,
      ),
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

  let entryPointCode = `import { ECSClient, RunTaskCommand } from "@aws-sdk/client-ecs";
const client = new ECSClient();
export const handler = async (event) => {
  const environment = Object.fromEntries([
    ["REVENTLESS_CORE_STACK", process.env.STACK_ORG + "/" + process.env.STACK_PROJECT + "/" + process.env.STACK_STACK],
    ["RESTORE_DATE_TIME", event.restoreDateTime],
  ]);
  console.log("clone: requested by user " + event.meta.user + " from ip " + event.meta.ip);
  await client.send(new RunTaskCommand({
    taskDefinition: process.env.TASK_DEFINITION_ARN,
    cluster: process.env.CLUSTER_ARN,
    launchType: "FARGATE",
    networkConfiguration: { awsvpcConfiguration: { subnets: JSON.parse(process.env.SUBNETS) } },
    overrides: {
      containerOverrides: [{
        name: "reventless-ci",
        command: ["reventless-ci", "clone-environment"],
        environment: environment,
      }],
    },
  }));
};`
  let clonerArchiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
  clonerArchiveContents->Dict.set(
    "index.mjs",
    Pulumi.Asset.stringAsset(entryPointCode)->Pulumi.Archive.assetToAssetOrArchive,
  )
  // ESM self-containment: the handler imports @aws-sdk/client-ecs, provided by the
  // nodejs22.x runtime only under /var/runtime — unreachable from /var/task ESM
  // without the resolver hook. Ship the loader + set its env vars on the Lambda.
  let loaderHash = Util_Bundle.addEsmLoaderAssets(clonerArchiveContents)
  let code = Pulumi.Archive.assetArchive(clonerArchiveContents)
  let sourceCodeHash = Util_Bundle.hashString(entryPointCode ++ "\n---\n" ++ loaderHash)

  let layers =
    Lambda.reventlessLayerArn
    ->Option.map(arn => [arn->Pulumi.Input.make])
    ->Option.getOr([])
    ->Pulumi.Input.make

  let vpcStackName = Pulumi.Config.make(Some("vpc"))->Pulumi.Config.get("stack")->Option.getOrThrow
  let vpcConfig = Util_Vpc.getVpcConfig(~stackName=vpcStackName, ~outputName="vpc")

  let secrets =
    secretUrns
    ->Array.map(urn =>
      PulumiAws.GetSecretVersion.getSecretNames(urn)->Pulumi.Output.apply(names =>
        names->Array.map(name => {ECS.Container.name, valueFrom: `${urn}:${name}::`})
      )
    )
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(s => Array.flat(s))

  let resources =
    (secretsManagerAccessPolicy.arn, taskRunnerPolicy.arn, vpcConfig, secrets)
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((
      _secretsManagerAccessPolicyArn,
      _taskRunnerPolicyArn,
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
          ->JSON.stringifyAny
          ->Option.getOrThrow
          ->Pulumi.Input.make,
          executionRoleArn: taskExecutionRole.arn->Pulumi.Output.asInput,
          memory: "4096"->Pulumi.Input.make,
          cpu: "1024"->Pulumi.Input.make,
          requiresCompatibilities: ["FARGATE"],
          networkMode: #awsvpc,
          tags: AWS.Tags.make(
            ~name,
            ~kind=ReventlessCore.Cloner.componentType,
            ~role=DataTransfer,
            ~component=name,
          ),
        },
        ~opts?,
      )

      let lambdaRole = PulumiAws.IAM.Role.makeWithDefaultPolicy(
        ~name,
        ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
        ~tags=AWS.Tags.make(~name, ~kind=ReventlessCore.Cloner.componentType, ~role=Identity),
        ~opts?,
      )

      let lambda = Lambda.Function.make(
        ~name,
        ~args={
          handler: "index.handler"->Pulumi.Input.make,
          runtime: "nodejs22.x"->Pulumi.Input.make,
          code: code->Pulumi.Input.make,
          sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
          role: lambdaRole.arn->Pulumi.Output.asInput,
          memorySize: 1024->Pulumi.Input.make,
          timeout: 180->Pulumi.Input.make,
          layers,
          tags: AWS.Tags.make(~name, ~kind=ReventlessCore.Cloner.componentType, ~role=DataTransfer),
          environment: (
            {
              Lambda.Function.variables: Dict.fromArray([
                ("TASK_DEFINITION_ARN", taskDefinition.arn->Pulumi.Output.asInput),
                ("CLUSTER_ARN", cluster.arn->Pulumi.Output.asInput),
                (
                  "STACK_ORG",
                  fullQualifiedStackName.organization->Pulumi.Input.make,
                ),
                (
                  "STACK_PROJECT",
                  fullQualifiedStackName.project->Pulumi.Input.make,
                ),
                ("STACK_STACK", fullQualifiedStackName.stack->Pulumi.Input.make),
                (
                  "SUBNETS",
                  vpcConfig.subnetIds
                  ->JSON.stringifyAny
                  ->Option.getOr("[]")
                  ->Pulumi.Input.make,
                ),
                ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
                ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
                ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
              ]),
            }: Lambda.Function.functionEnvironment
          )->Pulumi.Input.make,
        },
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
        ~tags=AWS.Tags.make(
          ~name=name ++ "DS",
          ~kind=ReventlessCore.Cloner.componentType,
          ~role=Identity,
          ~component=name,
        ),
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

      let invokeCloneCode =
        `import { util } from '@aws-appsync/utils';
export function request(ctx) {
  return {
    operation: 'Invoke',
    payload: {
      restoreDateTime: ctx.args.restoreDateTime,
      meta: {
        ip: ctx.identity.sourceIp,
        user: ctx.identity.username
      }
    }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`->Pulumi.Input.make

      let field = ReventlessCore.Platform_AdminApi.cloneMutationEntry.fieldNames->Array.getUnsafe(0)
      let resolver = AppSync_Resolver_Retrying.makeUnitJsResolver(
        ~name=field,
        ~api,
        ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
        ~type_="Mutation"->Pulumi.Input.make,
        ~field=field->Pulumi.Input.make,
        ~code=invokeCloneCode,
        ~opts?,
      )

      [resolver->Util_AppSync.toResourceNative]
    })

  {resources: resources}
}
