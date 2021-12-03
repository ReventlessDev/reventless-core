open Reventless;
open PulumiAws;

type api = Pulumi.Output.t(AppSync.GraphQLApi.t);

let make: Cloner.Adapter.runnerMaker(api) =
  (
    ~name,
    ~api: api,
    ~fullQualifiedStackName,
    ~reventlessCiSecretUrn,
    ~secretUrns,
    ~opts=?,
    (),
  ) => {
    let cluster =
      ECS.Cluster.(
        make(
          ~name,
          ~args=Args.make(~name=name->Pulumi.Input.wrap, ()),
          ~opts,
        )
      );

    let containerDefinitions =
      [|
        ECS.Container.(
          ContainerDefinition.make(
            ~name="reventless-ci",
            ~image=
              Pulumi.Config.make(Some("ci"))
              ->Pulumi.Config.require("image"),
            ~memory=512,
            ~secrets=[|
              Secret.make(
                ~name="reventless-ci",
                ~valueFrom=reventlessCiSecretUrn,
              ),
            |],
            (),
          )
        ),
      |]
      ->Js.Json.stringifyAny
      ->Belt.Option.getExn;

    let secretsManagerAccessPolicy =
      IAM.Policy.(
        make(
          ~name="secretsManagerAccess",
          ~args=
            Args.makeFromString(
              ~policy=
                {|{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Action": [
              "secretsmanager:GetRandomPassword",
              "secretsmanager:GetResourcePolicy",
              "secretsmanager:GetSecretValue",
              "secretsmanager:DescribeSecret",
              "secretsmanager:ListSecretVersionIds"
          ],
          "Resource": "*"
      }
  ]
}
                   |}
                ->Pulumi.Input.wrap,
              (),
            ),
          (),
        )
      );

    let taskExecutionRole =
      IAM.Role.make(
        ~name=name ++ "TaskExecution",
        ~args=
          IAM.Role.Args.make(
            ~assumeRolePolicy=
              {|{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
              |}
              ->Pulumi.Input.wrap,
            ~inlinePolicies=
              [|
                IAM.InlinePolicy.make(
                  ~name="clonerTask",
                  ~policy=
                    {|{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Action": [
              "logs:PutLogEvents",
              "logs:CreateLogStream"
          ],
          "Resource": "*"
      }
  ]
}
                   |},
                ),
              |]
              ->Pulumi.Input.wrap,
            (),
          ),
        (),
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

    let taskDefinition =
      ECS.TaskDefinition.(
        make(
          ~name,
          ~args=
            Args.make(
              ~family=name->Pulumi.Input.wrap,
              ~containerDefinitions=containerDefinitions->Pulumi.Input.wrap,
              ~executionRoleArn=taskExecutionRole##arn->Pulumi.Output.asInput,
              ~memory="512"->Pulumi.Input.wrap,
              ~cpu="256"->Pulumi.Input.wrap,
              ~requiresCompatibilities=[|"FARGATE"|],
              ~networkMode=`awsvpc,
              (),
            ),
          ~opts,
        )
      );

    let lambda =
      Lambda.CallbackFunction.make(
        ~name,
        ~args=
          Lambda.CallbackFunction.Args.make(
            ~policies=
              secretsManagerAccessPolicy##arn
              ->Pulumi.Output.apply(arn => [|arn|])
              ->Pulumi.Output.asInput,
            ~callback=
              ClonerRunner_Fargate_Runtime.clone(
                ~taskDefinition=taskDefinition##arn,
                ~cluster=cluster##arn,
                ~fullQualifiedStackName,
                ~secretUrns,
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

    let invokeClone = () => {j|
    {
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
        ~requestTemplate=invokeClone()->Pulumi.Input.wrap,
        ~responseTemplate=AppSync.Resolver.Templates.result->Pulumi.Input.wrap,
        ~kind=AppSync.Resolver.Unit,
        ~opts?,
        (),
      );

    {resources: [|resolver->Util_AppSync.toResource|]};
  };
