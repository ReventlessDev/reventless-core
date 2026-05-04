let make: ReventlessCore.Scheduler_Adapter.scheduledPublisherMaker = (~name, ~opts) => {
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
    resource: ReventlessInfra.Adapter.make(
      // urn carries the CloudWatch Events role ARN — bundled Lambdas read it
      // via Scheduler.outputs.resource.urn to call PutRule with the right roleArn.
      ~name=role.name,
      ~id=role.id,
      ~urn=role.arn,
      ~service="CloudWatchEvents"->Pulumi.Output.make,
      ~resourceType="aws:cloudwatch:EventRule"->Pulumi.Output.make,
    ),
    operations: ({
      createSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(
        role,
      ),
      deleteSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule,
    }: ReventlessInfra.Scheduler.operations)->Pulumi.Output.make,
  }
}
