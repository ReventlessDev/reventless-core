open ReventlessSpec.Schedule;
open AwsSdk.CloudWatchEvents;

let plural = count => count == 1 ? "" : "s";

let toScheduleExpression =
  fun
  | Single(year, month, day, hour, minute) => {j|cron($minute $hour $day $month ? $year)|j}
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
  | Weekdays(hour, minute) => {j|cron($minute $hour ? * MON-FRI *)|j}
  | WeekdaysAndSaturday(hour, minute) => {j|cron($minute $hour ? * MON-SAT *)|j};

let createSchedule: PulumiAws.IAM.Role.t => Reventless.Scheduler.createSchedule =
  role =>
    (. queueResources, schedule) =>
      switch (queueResources) {
      | [||] =>
        let err = "ScheduledPublisher_CloudWatchEvents_Runtime: createSchedule not possible: no Queue configured !";
        Js.log(err);
        Js.Exn.raiseError(err);
      | resources =>
        let resource = resources[0]; // FIXME
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
               ~arn=resource##urn->Pulumi.Output.get,
               ~id=resource##name->Pulumi.Output.get,
               ~input=schedule.payload,
             )
           )
        |> Js.Promise.then_(_ => Js.Promise.resolve());
      };

let deleteSchedule: Reventless.Scheduler.deleteSchedule =
  (. queueResources, name) =>
    switch (queueResources) {
    | [||] =>
      let err = "ScheduledPublisher_CloudWatchEvents_Runtime: deleteSchedule not possible: no Queue configured !";
      Js.log(err);
      Js.Exn.raiseError(err);
    | resources =>
      let resource = resources[0]; // FIXME
      removeTarget(~rule=name, ~id=resource##name->Pulumi.Output.get)
      |> Js.Promise.then_(_ =>
           deleteRule(~name) |> Js.Promise.then_(_ => Js.Promise.resolve())
         )
      |> Js.Promise.then_(_ => Js.Promise.resolve());
    };
