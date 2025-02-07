open Reventless.Scheduler.Adapter

let make: scheduledPublisherMaker = (~name as _, ~opts) => {
  let role = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name="CloudWatchEventsRole",
    ~service="events.amazonaws.com"->Pulumi.Output.make,
    ~opts,
  )

  let _policy = PulumiAws.IAM.Policy.make(
    ~name="CloudWatchEventsPolicy",
    ~args={
      PulumiAws.IAM.Policy.policy: role.arn
      ->Pulumi.Output.apply(roleArn => PulumiAws.IAM.Policy.String(
        `{
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Action": "events:*",
            "Resource": "*"
          },{
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "${roleArn}"
        }]
        }`,
      ))
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
    createSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(role),
    deleteSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule,
  }
}
