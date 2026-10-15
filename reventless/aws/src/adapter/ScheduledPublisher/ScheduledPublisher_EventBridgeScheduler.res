let make: ReventlessCore.Scheduler_Adapter.scheduledPublisherMaker = (~name, ~opts) => {
  let tags = name =>
    AWS.Tags.make(
      ~name,
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Identity,
      ~scope=Platform,
    )

  // The role EventBridge Scheduler assumes to deliver a schedule's payload to its queue.
  let role = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name=ScheduledPublisher_EventBridgeScheduler_Runtime.roleName,
    ~servicePrincipal=AWS.EventBridgeScheduler.principal->Pulumi.Output.make,
    ~tags=tags(ScheduledPublisher_EventBridgeScheduler_Runtime.roleName),
    ~opts,
  )

  let _sendPolicy = PulumiAws.IAM.RolePolicy.make(
    ~name=name ++ "SchedulerSendPolicy",
    ~args={
      policy: {
        open PulumiAws.PolicyDocument
        PulumiAws.PolicyDocument.make(
          ~id=name ++ "SchedulerSendPolicy",
          ~statements=[
            {
              sid: "AllowSchedulerToSendToQueues",
              effect: Allow,
              actions: Action("sqs:SendMessage"),
              resources: AllResources,
            },
          ],
        )->toJsonString
      }->Pulumi.Input.make,
      role: role.id->Pulumi.Output.asInput,
    },
    ~opts,
  )

  // Named after the role: the runtime finds the group from the role ARN it is given.
  let _group = PulumiAws.Scheduler.ScheduleGroup.make(
    ~name=name ++ "ScheduleGroup",
    ~args={
      name: role.name->Pulumi.Output.asInput,
      tags: tags(name ++ "ScheduleGroup"),
    },
    ~opts,
  )

  {
    resource: ReventlessInfra.Adapter.make(
      // urn carries the scheduler role ARN — bundled Lambdas read it via
      // Scheduler.outputs.resource.urn, for the target's role and the group's name.
      ~name=role.name,
      ~id=role.id,
      ~urn=role.arn,
      ~service="EventBridgeScheduler"->Pulumi.Output.make,
      ~resourceType="aws:scheduler:ScheduleGroup"->Pulumi.Output.make,
    ),
    operations: role.arn->Pulumi.Output.apply((roleArn): ReventlessInfra.Scheduler.operations => {
      createSchedule: ScheduledPublisher_EventBridgeScheduler_Runtime.createSchedule(~roleArn),
      deleteSchedule: ScheduledPublisher_EventBridgeScheduler_Runtime.deleteSchedule(~roleArn),
    }),
  }
}
