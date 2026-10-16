// A digest per recipient on the local platform: the slice declares no time; a
// recipient's choice sets their schedule, unsubscribing clears it, and each tick
// sends that recipient's digest. The slice is made by `makeSlice`, so a test can fix
// the time first.

open TestFixtures
open Reventless

module PreferencesSource = {
  module Id = Id.String
  let name = "DigestPreferencesEventTopic"
  @schema
  type event =
    | DigestTimeChosen({recipientId: string, time: Schedule.time})
    | Unsubscribed({recipientId: string})
}

module DigestSpec = {
  let name = "LocalDigest"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type todoItem = {recipientId: string}

  @schema
  type command = SendDigest({recipientId: @s.matches(DcbTag.string) string})

  let maxRetries = 2
  let heartbeatInterval = 60
  let targetName = "SendDigest"
  let schedule = None
}

module FromClock = AutomationSlice.Mapping.Make(
  Clock,
  DigestSpec,
  {
    let collect = (Clock.Tick({key, at}), ~sourceId as _, _ctx) => [
      (Clock.itemId(key, at), ({recipientId: key}: DigestSpec.todoItem)),
    ]
    let resolve = _ => None
    let reschedule = _ => []
  },
)

module FromPreferences = AutomationSlice.Mapping.Make(
  PreferencesSource,
  DigestSpec,
  {
    let collect = (_, ~sourceId as _, _ctx) => []
    let resolve = _ => None
    let reschedule = event =>
      switch event {
      | PreferencesSource.DigestTimeChosen({recipientId, time}) => [
          AutomationSlice.Set({key: recipientId, time}),
        ]
      | Unsubscribed({recipientId}) => [Clear({key: recipientId})]
      }
  },
)

module DigestAutomation: AutomationSlice.Automation with module Spec := DigestSpec = {
  let process = (_id, item: DigestSpec.todoItem, ~now as _) => Some((
    item.recipientId,
    DigestSpec.SendDigest({recipientId: item.recipientId}),
  ))
  let onExhausted = (_id, _item: DigestSpec.todoItem) => None
  let moduleUrl: string = %raw(`import.meta.url`)
  module M = AutomationSlice.Mappings.Make(DigestSpec)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = [module(FromClock), module(FromPreferences)]
}

let preferencesResource: ReventlessInfra.Adapter.resource = ReventlessInfra.Adapter.make(
  ~name=PreferencesSource.name->Pulumi.Output.make,
  ~id=PreferencesSource.name->Pulumi.Output.make,
  ~urn=PreferencesSource.name->Pulumi.Output.make,
  ~service="memory:InMemory"->Pulumi.Output.make,
)

module Bus = LocalBus.Make()
let _ = TestRunner.setup()

module AutomationSliceMaker = AutomationSlice_Builder.Make(Bus)
module Digest = AutomationSliceMaker.Make(DigestSpec, DigestAutomation)

let publishedCommands: ref<array<Reventless.Message.commandJson>> = ref([])
let publishJsons: ReventlessInfra.CommandTopic.publishJsons = async cmds =>
  publishedCommands := publishedCommands.contents->Array.concat(cmds)

let makeSlice = () =>
  Digest.make(
    ~allEventTopics=Dict.fromArray([
      (PreferencesSource.name, {ReventlessInfra.EventTopic.resources: [preferencesResource]}),
    ]),
    ~publishJsons=publishJsons->Pulumi.Output.make,
    ~context={
      environment: "local",
      platformName: "local",
      pluginName: "TestPlugin",
      sliceName: DigestSpec.name,
    },
  )

/** An event as the log would hold it, recorded now as the fake Date has it. */
let eventJson = (event: PreferencesSource.event, ~recipientId) => {
  let meta = {
    ...makeTestMeta(~service=PreferencesSource.name),
    time: Date.now()->Date.fromTime->Date.toISOString,
  }
  (
    meta,
    JSON.Encode.object(
      Dict.fromArray([
        ("id", recipientId->JSON.Encode.string),
        ("meta", meta->Reventless.Util_Sury.toJson(Message.metaSchema)),
        ("event", event->Reventless.Util_Sury.toJson(PreferencesSource.eventSchema)),
      ]),
    ),
  )
}

let publish = async (event, ~recipientId) => {
  let (meta, json) = eventJson(event, ~recipientId)
  await Bus.publishEvent(PreferencesSource.name, "test", meta, json)
}

/** The keys and times the schedules store holds. */
let storedSchedules = () =>
  Bus.getQueryDbScan(Digest.schedulesDbName->Option.getOr(""))
  ->Option.map(scan => scan())
  ->Option.getOr([])
  ->Array.map(row =>
    row->Reventless.Util_Sury.fromJson(ReventlessCore.AutomationSlice_Schedules.rowSchema)
  )
  ->Array.filterMap(row =>
    row->ReventlessCore.AutomationSlice_Schedules.timeOf->Option.map(t => (row.key, t))
  )
  ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))

/** The keys whose timers the local platform holds for the slice. */
let timers = () => LocalAutomationSchedules.platformFor(~slice=DigestSpec.name).names()
