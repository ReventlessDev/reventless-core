open Reventless.Cloner;

let clone =
    (~taskDefinition, ~cluster, ~fullQualifiedStackName, ~subnets, payload, _) => {
  Js.log(
    "clone: requested by user "
    ++
    payload##meta##user
    ++ " from ip "
    ++
    payload##meta##ip,
  );

  let {organization, project, stack} = fullQualifiedStackName;

  let environment =
    AwsSdk.ECS.KeyValuePair.(
      [|
        make(
          ~name="REVENTLESS_CORE_STACK",
          ~value={j|$organization/$project/$stack|j},
        ),
        make(~name="RESTORE_DATE_TIME", ~value=payload##restoreDateTime),
      |]
    );

  AwsSdk.ECS.(
    make()
    ->runTask(
        ~params=
          RunTaskRequest.make(
            ~taskDefinition=taskDefinition->Pulumi.Output.get,
            ~cluster=cluster->Pulumi.Output.get,
            ~networkConfiguration=
              NetworkConfiguration.make(
                ~awsvpcConfiguration=AwsVpcConfiguration.make(~subnets),
                (),
              ),
            ~launchType=`FARGATE,
            ~overrides=
              TaskOverride.make(
                ~containerOverrides=[|
                  ContainerOverride.make(
                    ~name="reventless-ci",
                    ~environment,
                    ~command=[|"reventless-ci", "clone-environment"|],
                    (),
                  ),
                |],
                (),
              ),
            (),
          ),
      )
  )
  ->AwsSdk.Request.promise;
};
