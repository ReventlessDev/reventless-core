open Scheduler;
open AwsSdk.CloudWatchEvents;

let toScheduleExpression =
  fun
  | Daily(hour, minute) => {j|cron($minute $hour * * * *)|j}
  | Weekdays(hour, minute) => {j|cron($minute $hour ? * MON-FRI *)|j};

let createSchedule = role =>
  (. {id, urn}, schedule) => {
    putRule(
      ~name=schedule.name,
      ~scheduleExpression=schedule.rate->toScheduleExpression,
      ~roleArn=role##arn->Pulumi.Output.get,
      ~state="ENABLED",
      (),
    )
    |> Js.Promise.then_(_ =>
         putTarget(
           ~rule=schedule.name,
           ~arn=urn,
           ~id,
           ~input=schedule.payload,
         )
       )
    |> Js.Promise.then_(_ => Js.Promise.resolve());
  };

let deleteSchedule =
  (. {id}, name) => {
    removeTarget(~rule=name, ~id)
    |> Js.Promise.then_(_ =>
         deleteRule(~name) |> Js.Promise.then_(_ => Js.Promise.resolve())
       )
    |> Js.Promise.then_(_ => Js.Promise.resolve());
  };