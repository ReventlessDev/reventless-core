// The deployed aggregate handler, wired exactly as `AggregateEntryPoint.mjs` wires it,
// over an in-memory storage in place of DynamoDB.
//
// The shell is hand-written JS that passes the compiled EventLog operations MODULE
// where the aggregate callback expects the `EventLog.operations` RECORD, so a field
// the record has and the module does not export under the same name type-checks
// everywhere and fails only in a Lambda. That is how a primed field
// (`replayStream'`, exported as `replayStream$p`) took down every command of the
// platform's Plugin aggregate on AWS while every in-process test passed. The
// command that broke was a derived one — it carries the stable-id header, which
// sends the handler down the cause-reading replay — so that is the command sent
// here, its redelivery, and a plain command, which between them reach every
// operation the aggregate callback reads.

open JestGlobals

module Spec = AggTestAggregate

// ── An in-memory storage, typed by the contract the shell's storage satisfies ──

let stored: dict<array<JSON.t>> = Dict.make()

let storage: ReventlessCore.EventLog_Adapter.operations = {
  append: async (seq, id, events) => {
    let current = stored->Dict.get(id)->Option.getOr([])
    if current->Array.length != seq {
      Error(ReventlessCore.EventLog.Conflict)
    } else {
      stored->Dict.set(id, current->Array.concat(events))
      Ok()
    }
  },
  replay: async id => stored->Dict.get(id)->Option.getOr([]),
  replayStream: (id, ~fromSeq=0) =>
    Stream.fromIterable(stored->Dict.get(id)->Option.getOr([])->Array.slice(~start=fromSeq)),
  appendStream: (_, _, _) => Effect.succeed(),
  latestSnapshot: async _ => Ok(None),
  writeSnapshot: async (_, _) => Ok(),
}

// ── The shell's own wiring ────────────────────────────────────────────────────

type parts = {handleJsonCommands: ReventlessCore.CommandTopic_Helpers.jsonCommandsHandler}

let buildParts: ReventlessCore.EventLog_Adapter.operations => promise<parts> = %raw(`
  async (storage) => {
    const { buildAggregateParts } = await import(
      "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs"
    );
    const spec = await import("./integration/AggTestAggregate.res.mjs");
    const decision = await import("./integration/AggTestAggregateDecision.res.mjs");
    return buildAggregateParts(
      spec,
      decision,
      "agg-wiring-test",
      "https://sqs.eu-west-1.amazonaws.com/000000000000/agg-wiring-test",
      undefined,
      () => storage,
    );
  }
`)

/** A command a mapping derived: its id is stable across redeliveries, and the
    header says so. */
let derived = (~id, ~msgId, name): JSON.t => {
  let meta: Reventless.Message.meta = {
    service: "AggWiringTest",
    time: "2026-11-01T00:00:00.000Z",
    msgId,
    correlationId: msgId,
    headers: Dict.fromArray([(ReventlessInfra.Message.stableIdHeader, "true")]),
  }
  ReventlessCore.Message.encodeCommand'(
    {
      Reventless.Message.id: Reventless.Id.String.makeFromString(id),
      meta,
      command: Spec.Add({name: name}),
    },
    Reventless.Id.String.schema,
    Spec.commandSchema,
  )
}

let send = async (parts: parts, json) =>
  await parts.handleJsonCommands(
    Stream.fromIterable([{ReventlessInfra.CommandTopic.reference: "r", command: json}]),
  )->Effect.runPromise

describe("the deployed aggregate handler's wiring", () => {
  beforeEach(() => stored->Dict.keysToArray->Array.forEach(k => stored->Dict.delete(k)))

  testPromise("handles a derived command, which replays its stream with causes", async () => {
    let parts = await buildParts(storage)
    let results = await send(parts, derived(~id="a-1", ~msgId="m-1", "first"))
    expect(results->Array.every(Result.isOk))->toBe(true)
    expect(stored->Dict.get("a-1")->Option.map(Array.length))->toEqual(Some(1))
  })

  testPromise("appends nothing for a redelivery of a derived command", async () => {
    let parts = await buildParts(storage)
    let _ = await send(parts, derived(~id="a-2", ~msgId="m-2", "first"))
    let again = await send(parts, derived(~id="a-2", ~msgId="m-2", "first"))
    expect(again->Array.every(Result.isOk))->toBe(true)
    expect(stored->Dict.get("a-2")->Option.map(Array.length))->toEqual(Some(1))
  })

  // An API command: no stable id, so the handler seeds from the snapshot read and
  // replays events alone — the other operations the shell's module must carry.
  testPromise("handles a command with a fresh id after a derived one", async () => {
    let parts = await buildParts(storage)
    let _ = await send(parts, derived(~id="a-3", ~msgId="m-3", "first"))
    let fresh = derived(~id="a-3", ~msgId="m-4", "second")
    switch fresh {
    | Object(d) =>
      d
      ->Dict.get("meta")
      ->Option.flatMap(JSON.Decode.object)
      ->Option.forEach(meta => meta->Dict.delete("headers"))
    | _ => ()
    }
    let results = await send(parts, fresh)
    expect(results->Array.every(Result.isOk))->toBe(true)
  })
})
