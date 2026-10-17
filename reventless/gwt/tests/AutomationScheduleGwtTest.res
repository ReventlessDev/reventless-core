// A declared schedule: the demand report every morning at 06:00. The slice maps the
// framework's Clock source; each tick makes the day's item, `process` requests the
// report, and the event that request records completes the item. The catalog team
// can move the report or stop it with an event, which replaces the declared time.

module DemandReport = {
  let name = "DemandReport"
  let moduleUrl = ""

  @schema
  type todoItem = {day: float}

  @schema
  type command = RequestDemandReport({day: float})

  let maxRetries = 3
  let targetName = "ReportSettings"
  let schedule = Some(Reventless.Schedule.Calendar({calendar: Daily({hour: 6, minute: 0})}))
}

module DemandReport_Automation = {
  module M = Reventless.AutomationSlice.Mappings.Make(DemandReport)
  module type Mapping = M.Mapping
  let moduleUrl = ""

  module CatalogDcbSource = {
    module Id = Reventless.Id.String
    let name = "CatalogDcbEventLog"
    @schema
    type event =
      | DemandReportRequested({day: float})
      | DemandReportTimeChanged({time: Reventless.Schedule.time})
      | DemandReportStopped
  }

  module FromClock = Reventless.AutomationSlice.Mapping.Make(
    Reventless.Clock,
    DemandReport,
    {
      open Reventless.Clock
      let collect = (Tick({key, at}), ~sourceId as _, _ctx) => [
        (itemId(key, at), ({day: at}: DemandReport.todoItem)),
      ]
      let resolve = _ => None
      let reschedule = _ => []
    },
  )

  module FromCatalogDcb = Reventless.AutomationSlice.Mapping.Make(
    CatalogDcbSource,
    DemandReport,
    {
      let collect = (_, ~sourceId as _, _ctx) => []
      let resolve = event =>
        switch event {
        | CatalogDcbSource.DemandReportRequested({day}) =>
          Some(Reventless.Clock.itemId(Reventless.Clock.defaultKey, day))
        | _ => None
        }
      let reschedule = event =>
        switch event {
        | CatalogDcbSource.DemandReportTimeChanged({time}) => [
            Reventless.AutomationSlice.Set({key: Reventless.Clock.defaultKey, time}),
          ]
        | DemandReportStopped => [Clear({key: Reventless.Clock.defaultKey})]
        | DemandReportRequested(_) => []
        }
    },
  )

  let mappings: array<module(Mapping)> = [module(FromClock), module(FromCatalogDcb)]

  let process = (id, item: DemandReport.todoItem, ~now as _) => Some((
    id,
    DemandReport.RequestDemandReport({day: item.day}),
  ))
  let onExhausted = (_id, _item: DemandReport.todoItem) => None
}

open DemandReport
open DemandReport_Automation
include Automation_GWT.FromSlice(DemandReport, DemandReport_Automation)
module Catalog = Mapping(FromCatalogDcb)

let morning = Date.fromString("2026-10-16T06:00:00Z")->Date.getTime
let dayItem = "default@2026-10-16T06:00Z"

describe("a declared schedule", () => {
  test("the tick makes the day's item, and process requests the report", () =>
    givenEvents([])
    ->whenTick(~at=morning)
    ->thenCommands([(dayItem, RequestDemandReport({day: morning}))])
  )

  test("the same tick delivered twice makes one item", () =>
    givenEvents([tick(morning)])
    ->whenTick(~at=morning)
    ->thenScenarioTodos([(dayItem, {day: morning})])
  )

  test("the report's own event completes the day's item", () =>
    givenEvents([])
    ->whenTick(~at=morning)
    ->andThenEvents([Catalog.event(DemandReportRequested({day: morning}))])
    ->thenScenarioTodos([])
  )

  test("the item id is the key and the scheduled minute, in UTC", () =>
    givenEvents([])
    ->whenTick(~key="r1", ~at=Date.fromString("2026-10-16T18:00:42Z")->Date.getTime)
    ->thenScenarioTodos([
      ("r1@2026-10-16T18:00Z", {day: Date.fromString("2026-10-16T18:00:42Z")->Date.getTime}),
    ])
  )
})

let daily6 = Reventless.Schedule.Calendar({calendar: Daily({hour: 6, minute: 0})})
let weekdays730 = Reventless.Schedule.Calendar({
  calendar: Weekly({days: [Mon, Tue, Wed, Thu, Fri], hour: 7, minute: 30}),
})

describe("the same schedule, moved by an event", () => {
  test("with no event, the schedule is the declared one", () =>
    givenEvents([])->whenSweep(~now=morning)->thenSchedules([("default", daily6)])
  )

  test("an event replaces the declared time", () =>
    givenEvents([Catalog.event(DemandReportTimeChanged({time: weekdays730}))])
    ->whenSweep(~now=morning)
    ->thenSchedules([("default", weekdays730)])
  )

  test("an event that stops the report leaves no schedule", () =>
    givenEvents([Catalog.event(DemandReportTimeChanged({time: weekdays730}))])
    ->whenSweep(~now=morning)
    ->andThenEvents([Catalog.event(DemandReportStopped)])
    ->thenSchedules([])
  )
})
