let make: Reventless.Scheduler_Adapter.scheduledPublisherMaker = (~name, ~opts) => {
  let role = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name="CloudWatchEventsRole",
    ~servicePrincipal=AWS.CloudwatchEventRule.principal->Pulumi.Output.make,
    ~opts,
  )

  let _policy = PulumiAws.IAM.Policy.make(
    ~name=name ++ "CloudWatchEventsPolicy",
    ~args={
      PulumiAws.IAM.Policy.policy: role.arn
      ->Pulumi.Output.apply(roleArn => {
        open PulumiAws.PolicyDocument
        PulumiAws.PolicyDocument.make(
          ~id=name ++ "CloudWatchEventsPolicy",
          ~statements=[
            {
              sid: "AllowCloudWatchEvents",
              effect: Allow,
              actions: Action("events:*"),
              resources: AllResources,
            },
            {
              sid: "AllowPassRole",
              effect: Allow,
              actions: Action("iam:PassRole"),
              resources: Resource(`${roleArn}`),
            },
          ],
        )->toJsonString
      })
      ->Pulumi.Output.asInput,
    },
    ~opts,
  )

  {
    resource: {
      ReventlessSpec.Adapter.service: "CloudWatchEvents"->Pulumi.Output.make,
      name: ""->Pulumi.Output.make,
      id: ""->Pulumi.Output.make,
      urn: ""->Pulumi.Output.make,
      info: ""->Pulumi.Output.make,
    },
    operations: ({
      createSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(
        role,
      ),
      deleteSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule,
    }: ReventlessSpec.Scheduler.operations)->Pulumi.Output.make,
  }
}
