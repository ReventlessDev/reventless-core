// In-memory event log storage.
// Uses Stm.TRef for transactional state management, preparing for future
// atomic append+publish spanning storage and the event bus.
//
// When BackendState is set to Sqlite, the `Make(Bus)` functor delegates to
// EventLogStorage_Sqlite at `make` time so the same builder wiring serves
// both backends.

let makeMemoryStorage = (~name as _name, ~opts as _) => {
  let eventsRef =
    Stm.TRef.make(Dict.make())
    ->Stm.commit
    ->Effect.runSync

  // Keep-one snapshot per aggregate id. Node.js is single-threaded and snapshot
  // writes are fire-and-forget upserts, so a plain dict suffices (no Stm).
  let snapshots: dict<ReventlessCore.EventLog.snapshot> = Dict.make()

  let append: ReventlessCore.EventLog.append<string, JSON.t> = (seqNr, id, jsons) =>
    Stm.TRef.modify(eventsRef, events => {
      let existing = events->Dict.get(id)->Option.getOr([])
      let currentCount = existing->Array.length
      if seqNr != currentCount {
        (Error(ReventlessCore.EventLog.Conflict), events)
      } else {
        events->Dict.set(id, existing->Array.concat(jsons))
        (Ok(), events)
      }
    })
    ->Stm.commit
    ->Effect.runPromise

  // The in-memory array is already resident; expose it as a stream for API uniformity.
  // The real performance gain from streaming comes from the DynamoDB adapter.
  // Events are stored contiguously from seq 0, so the array index equals the
  // sequence number and `fromSeq` is a plain slice offset.
  let replayStream = (id, ~fromSeq=0) =>
    Stm.TRef.get(eventsRef)
    ->Stm.commit
    ->Effect.map(events =>
      events
      ->Dict.get(id)
      ->Option.getOr([])
      ->Array.filterWithIndex((_, i) => i >= fromSeq)
    )
    ->Stream.fromEffect
    ->Stream.flatMap(arr => Stream.fromIterable(arr))

  // Eager replay derived from replayStream.
  let replay: ReventlessCore.EventLog.replay<string, JSON.t> = id =>
    replayStream(id)->Stream.runCollect->Effect.runPromise

  let latestSnapshot: ReventlessCore.EventLog.latestSnapshot<string> = async id =>
    Ok(snapshots->Dict.get(id))

  let writeSnapshot: ReventlessCore.EventLog.writeSnapshot<string> = async (id, snap) => {
    snapshots->Dict.set(id, snap)
    Ok()
  }

  // Appends each stream item sequentially to storage.
  // Node.js is single-threaded so a plain ref is safe for the seqNr counter.
  let appendStream: ReventlessCore.EventLog.appendStream<string, JSON.t> = (startingSeqNr, id, stream) => {
    let seqNrRef = ref(startingSeqNr)
    stream->Stream.runForEach(json =>
      Stm.TRef.modify(eventsRef, events => {
        let existing = events->Dict.get(id)->Option.getOr([])
        let currentCount = existing->Array.length
        if seqNrRef.contents != currentCount {
          (Error("conflict"), events)
        } else {
          events->Dict.set(id, existing->Array.concat([json]))
          (Ok(), events)
        }
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

  (
    _name,
    replay,
    {
      ReventlessCore.EventLog_Adapter.resources: [],
      operations: Pulumi.Output.make({
        ReventlessCore.EventLog_Adapter.append,
        replay,
        replayStream,
        appendStream,
        latestSnapshot,
        writeSnapshot,
      }),
    },
  )
}

// Alias retained for tests that still want the pure-memory implementation.
let makeStorage = makeMemoryStorage

// Pure in-memory storageMaker (no BackendState dispatch, no Bus). Backend
// selection lives in LocalEventLogStorage.Make — this file holds only the
// in-memory implementation, as its name says.
let make: ReventlessCore.EventLog_Adapter.storageMaker = (~name, ~opts) => {
  let (_, _, storage) = makeMemoryStorage(~name, ~opts)
  storage
}
