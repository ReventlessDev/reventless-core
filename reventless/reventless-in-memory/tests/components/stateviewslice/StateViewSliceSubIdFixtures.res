// E2E test fixtures for StateViewSlice with sub-ID (composite sort key).
// Verifies that projection stores items with composite sub-keys and that
// loadStream returns them sorted.

open Reventless.Projection

// ─────────────────────────────────────────────────────────────
// Event type definition for the DcbEventLog
// ─────────────────────────────────────────────────────────────

module ScoreEventLog = {
  @schema
  type event =
    | ScoreRecorded({id: @s.matches(Reventless.DcbTag.string) string, category: string, date: string, score: int})
    | ScoreRemoved({id: @s.matches(Reventless.DcbTag.string) string, category: string, date: string})
}

// ─────────────────────────────────────────────────────────────
// StateViewSlice spec with composite sub-key (category + "/" + date)
// ─────────────────────────────────────────────────────────────

module ScoresViewSpec = {
  let name = "ScoresView"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type consumedEvent =
    | ScoreRecorded({id: string, category: string, date: string, score: int})
    | ScoreRemoved({id: string, category: string, date: string})

  @schema
  type state = {id: string, category: string, date: string, score: int}

  let config = Reventless.ReadModel.config()
  let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>> = Some({
    subIdField: "_subId",
    getSubId: (state: state) => state.category ++ "/" ++ state.date,
  })
}

module ScoresViewProjection = {
  module Spec = ScoresViewSpec
  open ScoresViewSpec

  let moduleUrl: string = %raw(`import.meta.url`)

  let project = (event: consumedEvent) =>
    switch event {
    | ScoreRecorded({id, category, date, score}) =>
      [Set(id, {id, category, date, score})]
    | ScoreRemoved({id, category: _, date: _}) =>
      [Delete(id)]
    }
}

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build DcbEventLog
// ─────────────────────────────────────────────────────────────

module ScoreEventLogMaker = DcbEventLog_Builder.Make(Bus)
let eventLog = ScoreEventLogMaker.make(
  ~name="ScoreEventLog",
  ~partitionTag=Reventless.DcbTag.Simple({key: "id"}),
)

// ─────────────────────────────────────────────────────────────
// Build StateViewSlice
// ─────────────────────────────────────────────────────────────

module SVMaker = StateViewSlice_Builder.Make(Bus)
module ScoresViewMaker = SVMaker.Make(ScoresViewSpec, ScoresViewProjection)
let sv = ScoresViewMaker.make(~dcbEventLog=eventLog)

let dcbEventTopicResource =
  (eventLog->ReventlessCore.Component.outputs).eventTopic.resources->Array.getUnsafe(0)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let encodeEvent = (event: ScoreEventLog.event): ReventlessInfra.DcbEventLog.rawEvent => {
  let json = event->Reventless.Util_Sury.toJson(ScoreEventLog.eventSchema)
  let (eventType, data) = json->ReventlessCore.Message.splitMessage
  let tags = Reventless.DcbTag.extractTags(ScoreEventLog.eventSchema, event)
  let meta = ReventlessCore.Message.generateMeta(~service="test")
  {eventType, data: JSON.Object(data), tags, meta}
}

let appendEvent = async event => {
  let ops = await eventLog->ScoreEventLogMaker.operations->TestRunner.resolve
  let _ = await ops.append([encodeEvent(event)])
}

let loadScores = async id => {
  switch Bus.getQueryDb("ScoresView") {
  | None => []
  | Some(ops) =>
    let states =
      await ops.loadStream(id)
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise
    states->Array.map(json => json->Reventless.Util_Sury.fromJson(ScoresViewSpec.stateSchema))
  }
}
