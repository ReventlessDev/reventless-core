// Mock in-memory event log storage.
// Conforms to ReventlessCore.EventLog_Adapter.storage.
// Adds reset() and failNextAppends counter for test isolation and failure injection.

type t = {
  storage: ReventlessCore.EventLog_Adapter.storage,
  failNextAppends: ref<int>,
  reset: unit => unit,
}

let make = (~name as _="mock-event-log", ~opts as _: Pulumi.CustomResourceOptions.t={}) => {
  let events: ref<dict<array<JSON.t>>> = ref(Dict.make())
  let failNextAppends = ref(0)

  let append: ReventlessCore.EventLog.append<string, JSON.t> = async (_seqNr, id, jsons) => {
    if failNextAppends.contents > 0 {
      failNextAppends := failNextAppends.contents - 1
      Error(ReventlessCore.EventLog.StorageFailure("mock append failure"))
    } else {
      let existing = events.contents->Dict.get(id)->Option.getOr([])
      events.contents->Dict.set(id, existing->Array.concat(jsons))
      Ok()
    }
  }

  let replay: ReventlessCore.EventLog.replay<string, JSON.t> = async id => {
    events.contents->Dict.get(id)->Option.getOr([])
  }

  let replayStream: string => Stream.t<JSON.t, string, unit> = id =>
    events.contents->Dict.get(id)->Option.getOr([])->Stream.fromIterable

  let appendStream: ReventlessCore.EventLog.appendStream<string, JSON.t> = (_startingSeqNr, id, stream) =>
    stream->Stream.runForEach(json =>
      Effect.sync(() => {
        let existing = events.contents->Dict.get(id)->Option.getOr([])
        events.contents->Dict.set(id, existing->Array.concat([json]))
      })
    )

  let storage: ReventlessCore.EventLog_Adapter.storage = {
    resources: [],
    operations: Pulumi.Output.make({
      ReventlessCore.EventLog_Adapter.append,
      replay,
      replayStream,
      appendStream,
    }),
  }

  let reset = () => {
    events := Dict.make()
    failNextAppends := 0
  }

  {storage, failNextAppends, reset}
}
