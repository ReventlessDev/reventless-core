let make: Reventless.Scheduler_Adapter.scheduledPublisherMaker = (~name as _, ~opts) => {
  
  let role = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name="CloudWatchEventsRole",
    ~service="events.amazonaws.com"->Pulumi.Output.make,
    ~opts,
  )

  let _policy = 
    PulumiAws.IAM.Policy.make(
    ~name="CloudWatchEventsPolicy",
    ~args={
      PulumiAws.IAM.Policy.policy: role.arn
      ->Pulumi.Output.apply(roleArn => {
       open PulumiAws.PolicyDocument
        PulumiAws.PolicyDocument.make(
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
        )->PulumiAws.PolicyDocument.toJsonString
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
    operations: {
      Reventless.Scheduler.createSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(
        role,
      ),
      deleteSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule,
    }->Pulumi.Output.make,
  }
}
