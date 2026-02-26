S.enableJson()

// ─────────────────────────────────────────────────────────────
// Aggregate spec
// ─────────────────────────────────────────────────────────────

module AggSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestAggregate"

  @schema
  type command =
    | Create({name: string})
    | Rename({newName: string})

  @schema
  type event =
    | Created({name: string})
    | Renamed({newName: string})

  @schema
  type error =
    | AlreadyExists
    | NotFound
}

// ─────────────────────────────────────────────────────────────
// Behavior
// ─────────────────────────────────────────────────────────────

module TestBehavior = {
  module Spec = AggSpec
  type state = {name: string}

  let resolverConfig: Reventless.Behavior.resolverConfig<AggSpec.command> = {
    commandSchema: AggSpec.commandSchema,
    fields: ["name"],
  }

  let init = (event: AggSpec.event): state =>
    switch event {
    | Created({name}) => {name: name}
    | Renamed({newName}) => {name: newName}
    }

  let apply = (state: state, event: AggSpec.event): state =>
    switch event {
    | Created({name}) => {name: name}
    | Renamed({newName}) => {...state, name: newName}
    }

  let create = (command: AggSpec.command, _ctx, _errHandler): array<AggSpec.event> =>
    switch command {
    | Create({name}) => [AggSpec.Created({name: name})]
    | Rename(_) => []
    }

  let execute = (_state: state, command: AggSpec.command, _ctx, _errHandler): array<AggSpec.event> =>
    switch command {
    | Create(_) => []
    | Rename({newName}) => [AggSpec.Renamed({newName: newName})]
    }
}

// ─────────────────────────────────────────────────────────────
// Mock EventLog storage
// ─────────────────────────────────────────────────────────────

type mockEL = {
  appendFn: (int, string, array<Message.event'<string, AggSpec.event>>) => promise<result<unit, string>>,
  replayFn: string => promise<array<AggSpec.event>>,
  getAll: unit => array<Message.event'<string, AggSpec.event>>,
  failNextAppend: ref<bool>,
  reset: unit => unit,
}

let makeMockEL = (): mockEL => {
  let storedRef: ref<array<Message.event'<string, AggSpec.event>>> = ref([])
  let failRef = ref(false)

  let appendFn = async (_seqNr, _id, newEvents) =>
    if failRef.contents {
      failRef := false
      Error("append failed")
    } else {
      storedRef := storedRef.contents->Array.concat(newEvents)
      Ok(())
    }

  let replayFn = async id =>
    storedRef.contents
    ->Array.filter(e => e.id == id)
    ->Array.map(e => e.event)

  {
    appendFn,
    replayFn,
    getAll: () => storedRef.contents,
    failNextAppend: failRef,
    reset: () => {
      storedRef := []
      failRef := false
    },
  }
}

// Module-level shared mock — reset in beforeEach
let mock = makeMockEL()

// ─────────────────────────────────────────────────────────────
// TestOps satisfying Aggregate_Callback.Ops
// ─────────────────────────────────────────────────────────────

// Alias to preserve outer EventLog module reference inside inner EventLog definition
module OuterEventLog = EventLog

module TestOps = {
  module Spec = AggSpec
  module EventLog = {
    module Spec = {
      module Id = AggSpec.Id
      let name = "MockEventLog"
      @schema
      type event = AggSpec.event
    }
    type operations = {
      append: (
        int,
        string,
        array<Message.event'<string, AggSpec.event>>,
      ) => promise<result<unit, string>>,
      replay: string => promise<array<AggSpec.event>>,
    }
    type component = Component.t<OuterEventLog.t, OuterEventLog.outputs, operations>
    // Never called — satisfies module type only
    let make = (~name as _: string, ~opts as _=?): component => Obj.magic(0)
  }
  let eventLog: EventLog.operations = {
    append: mock.appendFn,
    replay: mock.replayFn,
  }
}

// ─────────────────────────────────────────────────────────────
// Callback handler under test
// ─────────────────────────────────────────────────────────────

module TestHandler = Aggregate_Callback.Make(AggSpec, TestBehavior, TestOps)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: "TestAggregate",
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "msg-1",
  correlationId: "corr-1",
}

let makeTopicItem = (~aggId="agg-1", reference, command): CommandTopic.topicItem<
  Message.command'<string, AggSpec.command>,
> => {
  command: {
    id: aggId,
    meta: testMeta,
    command,
  },
  reference,
}
