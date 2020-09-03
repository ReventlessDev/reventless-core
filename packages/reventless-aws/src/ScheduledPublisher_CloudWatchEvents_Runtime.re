open Reventless.Scheduler;
open AwsSdk.CloudWatchEvents;

let plural = count => count == 1 ? "" : "s";

let toScheduleExpression =
  fun
  | Minutes(minutes) => {
      let plural = minutes->plural;
      {j|rate($minutes minute$plural)|j};
    }
  | Hours(hours) => {
      let plural = hours->plural;
      {j|rate($hours hour$plural)|j};
    }
  | Days(days) => {
      let plural = days->plural;
      {j|rate($days day$plural)|j};
    }
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
