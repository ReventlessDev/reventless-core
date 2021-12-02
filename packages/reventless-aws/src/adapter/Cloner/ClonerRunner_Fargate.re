open Reventless;
open PulumiAws;

type api = Pulumi.Output.t(AppSync.GraphQLApi.t);

let make: Cloner.Adapter.runnerMaker(api) =
  (
    ~name,
    ~api: api,
    ~fullQualifiedStackName,
    ~containerSecretUrn,
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
            ~secrets=[|
              Secret.make(
                ~name="reventless-ci",
                ~valueFrom=containerSecretUrn,
              ),
            |],
            (),
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
              ~containerDefinitions=containerDefinitions->Pulumi.Input.wrap,
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
