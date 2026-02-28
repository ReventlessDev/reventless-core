// In-memory event log storage.
// Uses Stm.TRef for transactional state management, preparing for future
// atomic append+publish spanning storage and the event bus.

let make: ReventlessCore.EventLog_Adapter.storageMaker = (~name as _, ~opts as _) => {
  let eventsRef =
    Stm.TRef.make(Dict.make())
    ->Stm.commit
    ->Effect.runSync

  let append: ReventlessCore.EventLog.append<string, JSON.t> = (_seqNr, id, jsons) =>
    Stm.TRef.modify(eventsRef, events => {
      let existing = events->Dict.get(id)->Option.getOr([])
      events->Dict.set(id, existing->Array.concat(jsons))
      (Ok(), events)
    })
    ->Stm.commit
    ->Effect.runPromise

  let replay: ReventlessCore.EventLog.replay<string, JSON.t> = id =>
    Stm.TRef.get(eventsRef)
    ->Stm.commit
    ->Effect.map(events => events->Dict.get(id)->Option.getOr([]))
    ->Effect.runPromise

  // The in-memory array is already resident; expose it as a stream for API uniformity.
  // The real performance gain from streaming comes from the DynamoDB adapter.
  let replayStream: string => Stream.t<JSON.t, string, unit> = id =>
    Stm.TRef.get(eventsRef)
    ->Stm.commit
    ->Effect.map(events => events->Dict.get(id)->Option.getOr([]))
    ->Stream.fromEffect
    ->Stream.flatMap(arr => Stream.fromIterable(arr))

  // Appends each stream item sequentially to storage.
  // Node.js is single-threaded so a plain ref is safe for the seqNr counter.
  let appendStream: ReventlessCore.EventLog.appendStream<string, JSON.t> = (startingSeqNr, id, stream) => {
    let seqNrRef = ref(startingSeqNr)
    stream->Stream.runForEach(json =>
      Stm.TRef.modify(eventsRef, events => {
        let existing = events->Dict.get(id)->Option.getOr([])
        events->Dict.set(id, existing->Array.concat([json]))
        (Ok(), events)
      })
      ->Stm.commit
      ->Effect.flatMap(result =>
        switch result {
        | Ok() =>
          seqNrRef := seqNrRef.contents + 1
          Effect.succeed(())
        | Error(msg) => Effect.fail(msg)
        }
      )
    )
  }

  {
    resources: [],
    operations: Pulumi.Output.make({
      ReventlessCore.EventLog_Adapter.append,
      replay,
      replayStream,
      appendStream,
    }),
  }
}
