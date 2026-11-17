// A question reads the replies posted under it, end to end on DynamoDB Local:
// four slice callbacks over one event log, wired with the scope the deployed
// command handler derives (`DcbCommandTopicEntryPoint_Ops`). The local backends
// ignore partitions, so only a real table shows that the reply, stored under
// the reply, is read by the question, and that the pair's fence holds.

open JestGlobals

module H = DcbIntegrationHarness
module Q = QuestionSlices

let slices: array<Reventless.DcbTag.sliceSchemas> = [
  {
    name: Q.PostMessage.name,
    commandSchema: Q.PostMessage.commandSchema->S.castToUnknown,
    consumedEventSchema: Q.PostMessage.consumedEventSchema->S.castToUnknown,
    eventSchema: Q.PostMessage.eventSchema->S.castToUnknown,
    moduleUrl: Q.PostMessage.moduleUrl,
  },
  {
    name: Q.EditMessage.name,
    commandSchema: Q.EditMessage.commandSchema->S.castToUnknown,
    consumedEventSchema: Q.EditMessage.consumedEventSchema->S.castToUnknown,
    eventSchema: Q.EditMessage.eventSchema->S.castToUnknown,
    moduleUrl: Q.EditMessage.moduleUrl,
  },
  {
    name: Q.PostReply.name,
    commandSchema: Q.PostReply.commandSchema->S.castToUnknown,
    consumedEventSchema: Q.PostReply.consumedEventSchema->S.castToUnknown,
    eventSchema: Q.PostReply.eventSchema->S.castToUnknown,
    moduleUrl: Q.PostReply.moduleUrl,
  },
  {
    name: Q.QuestionState.name,
    commandSchema: Q.QuestionState.commandSchema->S.castToUnknown,
    consumedEventSchema: Q.QuestionState.consumedEventSchema->S.castToUnknown,
    eventSchema: Q.QuestionState.eventSchema->S.castToUnknown,
    moduleUrl: Q.QuestionState.moduleUrl,
  },
]

// The scope as the deployed command handler derives it.
let effective = Reventless.DcbTag.deriveEffectiveScope(slices)
let boundary = Reventless.DcbTag.deriveBoundaryPartition(slices)
let partitionOf = name => boundary->Reventless.DcbTag.slicePartitionTag(name)
let scope: DcbCommandTopicEntryPoint_Ops.derivedScope = {
  crossPartitionTagKeys: effective.crossPartitionTagKeys,
  crossPartitionPairs: effective.crossPartitionPairs,
  tagKeysByEventType: effective.tagKeysByEventType,
  partitionTag: boundary.partitionTag,
  partitionTagBySlice: slices
  ->Array.filterMap(s => partitionOf(s.name)->Option.map(p => (s.name, p)))
  ->Dict.fromArray,
}

let eventLogOf = (
  table: Util_DynamoDb_Runtime.resolvedTable,
): ReventlessInfra.DcbEventLog.operations => {
  module Ops = ReventlessCore.DcbEventLog_Operations.Make({
    let name = "Questions"
    let serviceName = "QuestionsDcbEventLog"
    let storage = DcbCommandTopicEntryPoint_Ops.makeDynamoStorageOps(~tableName=table.name, scope)
    let publishJson = async (_, _, _) => ()
  })
  {
    read: Ops.read,
    append: Ops.append,
    readStream: Ops.readStream,
    appendStream: Ops.appendStream,
    readFences: ?Ops.readFences,
  }
}

module PostMessage = ReventlessCore.StateChangeSlice_Callback.Make(
  Q.PostMessage,
  Q.PostMessageDecision,
)
module EditMessage = ReventlessCore.StateChangeSlice_Callback.Make(
  Q.EditMessage,
  Q.EditMessageDecision,
)
module PostReply = ReventlessCore.StateChangeSlice_Callback.Make(Q.PostReply, Q.PostReplyDecision)
module QuestionState = ReventlessCore.StateChangeSlice_Callback.Make(
  Q.QuestionState,
  Q.QuestionStateDecision,
)

let counter = ref(0)
let item = (sliceName, command) => {
  counter := counter.contents + 1
  let reference = `${sliceName}-${counter.contents->Int.toString}`
  {
    ReventlessInfra.CommandTopic.command: {
      ReventlessCore.Message.id: Reventless.Id.String.makeFromString(`cmd-${reference}`),
      meta: ReventlessCore.Message.generateMeta(~service="question-it"),
      command,
    },
    reference,
  }
}
let accepted = (result: array<result<string, string>>) =>
  switch result {
  | [Ok(_)] => true
  | _ => false
  }

let postMessage = (log, messageId) =>
  PostMessage.handleCommands(
    ~tagKeysByEventType=scope.tagKeysByEventType,
    ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    ~crossPartitionPairs=scope.crossPartitionPairs,
    ~partitionTag=?partitionOf(Q.PostMessage.name),
    log,
    Stream.fromIterable([item("post", Q.PostMessage.PostMessage({messageId: messageId}))]),
  )
  ->Effect.runPromise
  ->Promise.thenResolve(accepted)
let editMessage = (log, messageId) =>
  EditMessage.handleCommands(
    ~tagKeysByEventType=scope.tagKeysByEventType,
    ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    ~crossPartitionPairs=scope.crossPartitionPairs,
    ~partitionTag=?partitionOf(Q.EditMessage.name),
    log,
    Stream.fromIterable([item("edit", Q.EditMessage.EditMessage({messageId, text: "edited"}))]),
  )
  ->Effect.runPromise
  ->Promise.thenResolve(accepted)
let postReply = (log, ~messageId, ~replyId) =>
  PostReply.handleCommands(
    ~tagKeysByEventType=scope.tagKeysByEventType,
    ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    ~crossPartitionPairs=scope.crossPartitionPairs,
    ~partitionTag=?partitionOf(Q.PostReply.name),
    log,
    Stream.fromIterable([item("reply", Q.PostReply.PostReply({replyId, messageId}))]),
  )
  ->Effect.runPromise
  ->Promise.thenResolve(accepted)
let markAnswer = (log, ~messageId, ~replyId) =>
  QuestionState.handleCommands(
    ~tagKeysByEventType=scope.tagKeysByEventType,
    ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    ~crossPartitionPairs=scope.crossPartitionPairs,
    ~partitionTag=?partitionOf(Q.QuestionState.name),
    log,
    Stream.fromIterable([item("mark", Q.QuestionState.MarkAnswer({messageId, replyId}))]),
  )
  ->Effect.runPromise
  ->Promise.thenResolve(accepted)

let freshTable = async () => {
  counter := counter.contents + 1
  let table = await H.createDcbTableWithTagKeys(
    `DcbPairIt_${counter.contents->Int.toString}`,
    ["messageId", "replyId"],
  )
  // On an empty table every fence is counted, so the run records where it ran
  // and each fence written from now on is trusted from its first event.
  let _ = await DcbFenceBackfill.countAll(
    table,
    ~keys=[],
    ~pairs=[("messageId", "ReplyPosted")],
    ~recount=false,
    ~settleMs=0,
    ~dryRun=false,
  )
  table
}

let _ = beforeEach(() => {
  PostMessage.resetCache()
  EditMessage.resetCache()
  PostReply.resetCache()
  QuestionState.resetCache()
})

// What the question decided: the replies its stored answers name, in order.
let answersOf = async (table, messageId) =>
  (
    await DcbEventLogStorage_DynamoDb_Runtime.read(table)(
      ~query=[{tags: [{key: "messageId", value: messageId}], eventTypes: ["AnswerMarked"]}],
    )
  ).events->Array.filterMap(e =>
    // A partition read returns every event stored under the key; types are
    // the decision's to filter.
    e.eventType != "AnswerMarked"
      ? None
      : e.data
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("replyId"))
        ->Option.flatMap(JSON.Decode.string)
  )
let pairFenceOf = async (table, messageId) =>
  (
    await DcbEventLogStorage_DynamoDb_Runtime.readFences(
      table,
      ~pairFenceTypes=Dict.fromArray([("messageId", ["ReplyPosted"])]),
    )([{key: "messageId", value: messageId}])
  )->Array.map(f => (f.counted, f.counts->Dict.toArray))

describe("DCB DynamoDb integration — a question reads the replies under it", () => {
  testSync("the boundary resolves with one pair and no cross-partition key", () => {
    let hints = Reventless.DcbValidation.validatePartitionHintsVsInference(
      ~shapes=slices->Array.map(Reventless.DcbTag.sliceShape),
    )
    expect((
      hints.contradictions,
      effective.crossPartitionTagKeys,
      effective.crossPartitionPairs,
    ))->toEqual((
      [],
      [],
      [
        {
          Reventless.DcbScopeInference.reader: "QuestionState",
          eventType: "ReplyPosted",
          key: "messageId",
          writers: ["PostReply"],
        },
      ],
    ))
  })

  testAsync(
    "marks a reply stored under the reply, once, and only one under the question",
    async () => {
      let table = await freshTable()
      let log = eventLogOf(table)
      let _ = await postMessage(log, "m1")
      let _ = await postMessage(log, "m2")
      let _ = await postReply(log, ~messageId="m1", ~replyId="r1")
      let _ = await postReply(log, ~messageId="m1", ~replyId="r2")
      let _ = await postReply(log, ~messageId="m2", ~replyId="r3")
      // r3 is under m2: refused. r1 is under m1: marked. r2 then: already answered.
      let handled = [await markAnswer(log, ~messageId="m1", ~replyId="r3")]
      let _ = await markAnswer(log, ~messageId="m1", ~replyId="r1")
      let _ = await markAnswer(log, ~messageId="m1", ~replyId="r2")
      expect((handled, await answersOf(table, "m1"), await pairFenceOf(table, "m1")))->toEqual((
        [true],
        ["r1"],
        [(true, [("ReplyPosted", 2)])],
      ))
    },
  )

  testAsync("concurrent replies all land, and an edit of the question beside them", async () => {
    let table = await freshTable()
    let log = eventLogOf(table)
    let _ = await postMessage(log, "m1")
    let handled = await Promise.all([
      postReply(log, ~messageId="m1", ~replyId="r1"),
      postReply(log, ~messageId="m1", ~replyId="r2"),
      postReply(log, ~messageId="m1", ~replyId="r3"),
      editMessage(log, "m1"),
    ])
    let _ = await markAnswer(log, ~messageId="m1", ~replyId="r3")
    let edits =
      (
        await DcbEventLogStorage_DynamoDb_Runtime.read(table)(
          ~query=[{tags: [{key: "messageId", value: "m1"}], eventTypes: ["MessageEdited"]}],
        )
      ).events
      ->Array.filter(e => e.eventType == "MessageEdited")
      ->Array.length
    expect((
      handled,
      edits,
      await answersOf(table, "m1"),
      await pairFenceOf(table, "m1"),
    ))->toEqual(([true, true, true, true], 1, ["r3"], [(true, [("ReplyPosted", 3)])]))
  })
})
