// A declared schedule: the demand report every morning at 06:00 UTC. Its one
// mapping reads the framework's Clock source; each tick makes the day's item and
// `process` requests the report. The slice is made by `makeSlice`, not at import, so
// a test can fix the time its schedule is set at.

open Reventless

module DemandReportSpec = {
  let name = "LocalDemandReport"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type todoItem = {day: float}

  @schema
  type command = RequestDemandReport({day: float})

  let maxRetries = 2
  let heartbeatInterval = 60
  let targetName = "ReportSettings"
  let schedule = Some(Schedule.Calendar({calendar: Daily({hour: 6, minute: 0})}))
}

module FromClock = AutomationSlice.Mapping.Make(
  Clock,
  DemandReportSpec,
  {
    open Clock
    let collect = (Tick({key, at}), ~sourceId as _, _ctx) => [
      (itemId(key, at), ({day: at}: DemandReportSpec.todoItem)),
    ]
    let resolve = _ => None
  },
)

module DemandReportAutomation: AutomationSlice.Automation with module Spec := DemandReportSpec = {
  let process = (id, item: DemandReportSpec.todoItem, ~now as _) => Some((
    id,
    DemandReportSpec.RequestDemandReport({day: item.day}),
  ))
  let onExhausted = (_id, _item: DemandReportSpec.todoItem) => None
  let moduleUrl: string = %raw(`import.meta.url`)
  module M = AutomationSlice.Mappings.Make(DemandReportSpec)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = [module(FromClock)]
}

// The same slice with its schedule left out: nothing would ever tick it.
module UnscheduledSpec = {
  include DemandReportSpec
  let name = "LocalUnscheduledReport"
  let schedule: option<Schedule.time> = None
}

module FromClockUnscheduled = AutomationSlice.Mapping.Make(
  Clock,
  UnscheduledSpec,
  {
    let collect = (_, ~sourceId as _, _ctx) => []
    let resolve = _ => None
  },
)

module UnscheduledAutomation: AutomationSlice.Automation with module Spec := UnscheduledSpec = {
  let process = (_id, _item: UnscheduledSpec.todoItem, ~now as _) => None
  let onExhausted = (_id, _item: UnscheduledSpec.todoItem) => None
  let moduleUrl: string = %raw(`import.meta.url`)
  module M = AutomationSlice.Mappings.Make(UnscheduledSpec)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = [module(FromClockUnscheduled)]
}

module Bus = LocalBus.Make()
let _ = TestRunner.setup()

module AutomationSliceMaker = AutomationSlice_Builder.Make(Bus)
module DemandReport = AutomationSliceMaker.Make(DemandReportSpec, DemandReportAutomation)
module Unscheduled = AutomationSliceMaker.Make(UnscheduledSpec, UnscheduledAutomation)

let publishedCommands: ref<array<Reventless.Message.commandJson>> = ref([])
let publishJsons: ReventlessInfra.CommandTopic.publishJsons = async cmds =>
  publishedCommands := publishedCommands.contents->Array.concat(cmds)

let context = (sliceName): AutomationSlice.context => {
  environment: "local",
  platformName: "local",
  pluginName: "TestPlugin",
  sliceName,
}

/** Makes the demand report, which starts its declared schedule at the current time. */
let makeSlice = () =>
  DemandReport.make(
    ~allEventTopics=Dict.make(),
    ~publishJsons=publishJsons->Pulumi.Output.make,
    ~context=context(DemandReportSpec.name),
  )

let makeUnscheduled = () =>
  Unscheduled.make(
    ~allEventTopics=Dict.make(),
    ~publishJsons=publishJsons->Pulumi.Output.make,
    ~context=context(UnscheduledSpec.name),
  )

/** The stored to-do row of `id`, as the query store holds it. */
let storedRow = id =>
  Bus.getQueryDbScan(DemandReport.queryDbName)
  ->Option.map(scan => scan())
  ->Option.getOr([])
  ->Array.find(row =>
    row->JSON.Decode.object->Option.flatMap(o => o->Dict.get("id")) == Some(id->JSON.Encode.string)
  )
  ->Option.map(row =>
    row->Reventless.Util_Sury.fromJson(ReventlessCore.AutomationSlice_Callback.todoRowSchema)
  )
