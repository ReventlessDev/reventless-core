let make = (~name as _, ~opts) => {
  let role =
    PulumiAws.IAM.Role.makeWithDefaultPolicy(
      ~name="CloudWatchEventsRole",
      ~service="events.amazonaws.com"->Pulumi.Output.make,
      ~opts,
      (),
    );

  let _policy =
    PulumiAws.IAM.Policy.make(
      ~name="CloudWatchEventsPolicy",
      ~args=
        PulumiAws.IAM.Policy.Args.makeFromString(
          ~policy=
            role##arn
            ->Pulumi.Output.apply(roleArn =>
                {j|{
                    "Version": "2012-10-17",
                    "Statement": [{
                      "Effect": "Allow",
                      "Action": "events:*",
                      "Resource": "*"
                    },{
                      "Effect": "Allow",
                      "Action": "iam:PassRole",
                      "Resource": "$roleArn"
                  }]
                  }|j}
              )
            ->Pulumi.Output.asInput,
          (),
        ),
      ~opts,
      (),
    );

  Reventless.Scheduler.{
    resource:
      Reventless.Adapter.resource(
        ~service="CloudWatchEvents",
        ~name="" |> Pulumi.Output.make,
        ~id="" |> Pulumi.Output.make,
        ~urn="" |> Pulumi.Output.make,
        ~info="" |> Pulumi.Output.make,
      ),
    createSchedule:
      role->ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule,
    deleteSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule,
  };
};
