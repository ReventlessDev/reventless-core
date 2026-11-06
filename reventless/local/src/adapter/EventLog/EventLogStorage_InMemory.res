// In-memory event log storage.
// Keeps its state in a TxRef, so a future append+publish spanning storage and
// the event bus can run as one Effect.tx.
//
// When BackendState is set to Sqlite, the `Make(Bus)` functor delegates to
// EventLogStorage_Sqlite at `make` time so the same builder wiring serves
// both backends.

let makeMemoryStorage = (~name as _name, ~opts as _) => {
  // Every event of the log in the order it was appended, across entities, for
  // the read that runs newest first. The insertion number is its position.
  let ordered: array<LocalEventLogRead.stored> = []
  let keepOrdered = (~track: bool, id: string, jsons: array<JSON.t>) =>
    jsons->Array.forEach(json => {
      let position = (ordered->Array.length + 1)->Int.toFloat
      ordered->Array.push(LocalEventLogRead.storedOfFlat(~log=_name, ~position, ~entityId=id, json))
      if track {
        json
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get("msgId"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.forEach(msgId => LocalEventLogRead.note(~log=_name, ~msgId, ~position))
      }
    })
  LocalEventLogRead.register(~log=_name, ~kind=Aggregate, async (
    ~bound,
    ~limit,
    ~correlationId,
  ) => {
    let out = []
    let i = ref(ordered->Array.length - 1)
    while i.contents >= 0 && out->Array.length < limit {
      let r = ordered->Array.getUnsafe(i.contents)
      let inBound = switch bound {
      | Some(LocalEventLogRead.Below(p)) => r.position < p
      | Some(AtMost(p)) => r.position <= p
      | None => true
      }
      let inFlow =
        correlationId->Option.mapOr(true, id =>
          LocalEventLogRead.metaString(r.meta, "correlationId") == Some(id)
        )
      if inBound && inFlow {
        out->Array.push(r)
      }
      i := i.contents - 1
    }
    out
  })
  let eventsRef = TxRef.makeUnsafe(Dict.make())

  // Keep-one snapshot per aggregate id. Node.js is single-threaded and snapshot
  // writes are fire-and-forget upserts, so a plain dict suffices (no TxRef).
  let snapshots: dict<ReventlessCore.EventLog.snapshot> = Dict.make()

  let append: ReventlessCore.EventLog.append<string, JSON.t> = async (seqNr, id, jsons) => {
    let result = await TxRef.modify(eventsRef, events => {
      let existing = events->Dict.get(id)->Option.getOr([])
      let currentCount = existing->Array.length
      if seqNr != currentCount {
        (Error(ReventlessCore.EventLog.Conflict), events)
      } else {
        events->Dict.set(id, existing->Array.concat(jsons))
        (Ok(), events)
      }
    })->Effect.runPromise
    switch result {
    | Ok() => keepOrdered(~track=true, id, jsons)
    | Error(_) => ()
    }
    result
  }

  // The in-memory array is already resident; expose it as a stream for API uniformity.
  // The real performance gain from streaming comes from the DynamoDB adapter.
  // Events are stored contiguously from seq 0, so the array index equals the
  // sequence number and `fromSeq` is a plain slice offset.
  let replayStream = (id, ~fromSeq=0) =>
    TxRef.get(eventsRef)
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

  let latestSnapshot: ReventlessCore.EventLog.latestSnapshot<string> = async id => Ok(
    snapshots->Dict.get(id),
  )

  let writeSnapshot: ReventlessCore.EventLog.writeSnapshot<string> = async (id, snap) => {
    snapshots->Dict.set(id, snap)
    Ok()
  }

  // Appends each stream item sequentially to storage.
  // Node.js is single-threaded so a plain ref is safe for the seqNr counter.
  let appendStream: ReventlessCore.EventLog.appendStream<string, JSON.t> = (
    startingSeqNr,
    id,
    stream,
  ) => {
    let seqNrRef = ref(startingSeqNr)
    stream->Stream.runForEach(json =>
      TxRef.modify(eventsRef, events => {
        let existing = events->Dict.get(id)->Option.getOr([])
        let currentCount = existing->Array.length
        if seqNrRef.contents != currentCount {
          (Error("conflict"), events)
        } else {
          events->Dict.set(id, existing->Array.concat([json]))
          (Ok(), events)
        }
      })->Effect.flatMap(result =>
        switch result {
        | Ok() =>
          seqNrRef := seqNrRef.contents + 1
          keepOrdered(~track=false, id, [json])
          Effect.succeed()
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
let make: ReventlessCore.EventLog_Adapter.storageMaker = (~name, ~owner as _, ~opts) => {
  let (_, _, storage) = makeMemoryStorage(~name, ~opts)
  storage
}
