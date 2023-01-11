open Reventless.Scheduler.Adapter;

let make: scheduledPublisherMaker =
  (~name as _, ~opts) => {
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

    {
      resource:
        Reventless.Adapter.resource(
          ~service="CloudWatchEvents"->Pulumi.Output.make,
          ~name=""->Pulumi.Output.make,
          ~id=""->Pulumi.Output.make,
          ~urn=""->Pulumi.Output.make,
          ~info=""->Pulumi.Output.make,
        ),
      create:
        ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(role),
      delete: ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule,
    };
  };
