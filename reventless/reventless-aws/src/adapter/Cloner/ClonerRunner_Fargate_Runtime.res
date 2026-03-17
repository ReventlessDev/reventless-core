open ReventlessCore.Cloner

let clone = async (~taskDefinition, ~cluster, ~fullQualifiedStackName, ~subnets, payload, _) => {
  let {organization, project, stack} = fullQualifiedStackName

  let environment = {
    [
      ("REVENTLESS_CORE_STACK", `${organization}/${project}/${stack}`),
      ("RESTORE_DATE_TIME", payload["restoreDateTime"]),
    ]->Dict.fromArray
  }

  Console.log(
    "clone: requested by user " ++
    payload["meta"]["user"] ++
    " from ip " ++
    payload["meta"]["ip"],
  )

  let _ = await {
    taskDefinition: taskDefinition->Pulumi.Output.get,
    cluster: cluster->Pulumi.Output.get,
    networkConfiguration: {
      awsvpcConfiguration: {subnets},
    },
    launchType: #FARGATE,
    overrides: {
      containerOverrides: [
        {
          name: "reventless-ci",
          environment,
          command: ["reventless-ci", "clone-environment"],
        },
      ],
    },
  }
  ->AwsSdk.ECS.RunTaskCommand.make
  ->AwsSdk.ECS.RunTaskCommand.send
}
