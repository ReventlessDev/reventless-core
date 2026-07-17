S.enableJson()
// AutomationSlice callback — implements the TODO list pattern with mixed-source
// dispatch (Plan 04).
//
// Phase 1 (collect/resolve): for each event JSON, look up its source by
// `meta.service`, decode against the matching `Mapping.sourceEventSchema`, and
// run the mapping's `collect`/`resolve`. Multiple mappings may share a source
// name; all matching mappings run.
//
// Phase 2 (process): walk pending TODO items; for each, call
// `Automation.process` to construct the command, encode against the command
// schema (sury enforces `@s.matches` / `@compositePartitionTag` invariants
// here — failures mark the item Failed for retry), and publish via
// `publishJsons`. Publish failures revert all `Processing` items to Failed
// for the next heartbeat sweep.

@schema
type todoStatus =
  | Pending
  | Processing
  | Completed
  | Failed

@schema
type todoRow = {
  item: JSON.t,
  status: todoStatus,
  createdAt: string,
  processedAt?: string,
  completedAt?: string,
  retryCount: int,
}

module type T = {
  module Spec: Reventless.AutomationSlice.Spec
  module Automation: Reventless.AutomationSlice.Automation with module Spec := Spec

  /** The in-memory TODO list — maps item ID to row. */
  let todoItems: Dict.t<todoRow>

  /** Phase 1: update TODO list from a batch of raw event JSONs. Internally
      decodes per-source via the registered Mappings. */
  let phase1: (array<JSON.t>, Reventless.AutomationSlice.context) => unit

  /** Phase 2: process all pending items, publishing commands via publishJsons. */
  let phase2: ReventlessInfra.CommandTopic.publishJsons => promise<unit>
}

module Make = (
  Spec: Reventless.AutomationSlice.Spec,
  Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
): (T with module Spec = Spec and module Automation := Automation) => {
  module Spec = Spec
  module Automation = Automation

  let todoItems: Dict.t<todoRow> = Dict.make()

  let now = () => Date.make()->Date.toISOString

  // Root meta for commands emitted by this AutomationSlice. The triggering
  // event's meta is not currently threaded from phase1 → phase2 (todoItems
  // only carries `item` data), so causation across the automation hop is
  // lost — emitted commands are roots of a fresh correlation chain. If we
  // later thread source meta through todoItems, switch to deriveMeta.
  let makeMeta = (): Reventless.Message.meta =>
    Message.generateMeta(~service=`AutomationSlice:${Spec.name}`)

  // Per-source erased dispatch — pre-compile decoders once at module init.
  type dispatch = {
    sourceName: string,
    handle: (JSON.t, Reventless.AutomationSlice.context) => unit,
  }

  let dispatches: array<dispatch> = Automation.mappings->Array.map((
    module(M: Automation.Mapping),
  ) => {
    let decoder = Reventless.DcbDecode.makeDecoder(M.sourceEventSchema)
    let handle = (json: JSON.t, ctx: Reventless.AutomationSlice.context) => {
      let (eventType, dataDict) = json->Message.splitMessage
      switch decoder.decode(~eventType, ~data=dataDict) {
      | Some(event) =>
        // Collect — append new items keyed by ID; first writer wins (idempotent).
        M.collect(event, ctx)->Array.forEach(((id, item)) => {
          switch todoItems->Dict.get(id) {
          | Some(_) => () // Already exists — skip
          | None =>
            let row: todoRow = {
              item: item->S.reverseConvertToJsonOrThrow(Spec.todoItemSchema),
              status: Pending,
              createdAt: now(),
              retryCount: 0,
            }
            todoItems->Dict.set(id, row)
          }
        })
        // Resolve — mark a pending item as completed.
        switch M.resolve(event) {
        | Some(id) =>
          todoItems
          ->Dict.get(id)
          ->Option.forEach(row => {
            todoItems->Dict.set(id, {...row, status: Completed, completedAt: now()})
          })
        | None => ()
        }
      | None => ()
      }
    }
    {sourceName: M.sourceName, handle}
  })

  let phase1 = (events: array<JSON.t>, ctx: Reventless.AutomationSlice.context) => {
    events->Array.forEach(json => {
      let context = json->Message.decode(Reventless.Message.contextSchema)
      let sourceName = context.meta.service
      // Events arrive as `{id, meta, event}` envelopes (see Message.composeEventJson').
      // Per-mapping decoders work on the inner `event` payload (TAG + fields at
      // the top level), not the wrapper.
      let eventPayload = switch json->JSON.Decode.object {
      | Some(dict) => dict->Dict.get("event")->Option.getOr(json)
      | None => json
      }
      // Multiple mappings can share a sourceName; all matching dispatches run.
      dispatches->Array.forEach(d => {
        if d.sourceName == sourceName {
          d.handle(eventPayload, ctx)
        }
      })
    })
  }

  let phase2 = async (publishJsons: ReventlessInfra.CommandTopic.publishJsons) => {
    let pending =
      todoItems
      ->Dict.toArray
      ->Array.filter(((_, row)) =>
        row.status == Pending || (row.status == Failed && row.retryCount < Spec.maxRetries)
      )

    let commands = []

    pending->Array.forEach(((id, row)) => {
      let item = try row.item->S.parseJsonOrThrow(Spec.todoItemSchema)->Some catch {
      | exn =>
        let errMsg =
          exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        EffectLogger.logError(
          ~comp=`AutomationSlice(${Spec.name})`,
          `failed to decode todoItem: ${errMsg}`,
        )->Effect.runSync
        None
      }

      item->Option.forEach(item => {
        switch Automation.process(id, item) {
        | Some((targetId, command)) =>
          todoItems->Dict.set(id, {...row, status: Processing, processedAt: now()})
          let commandJson = try command
          ->S.reverseConvertToJsonOrThrow(Spec.commandSchema)
          ->Some catch {
          | exn =>
            let errMsg =
              exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
            EffectLogger.logError(
              ~comp=`AutomationSlice(${Spec.name})`,
              `failed to encode command: ${errMsg}`,
            )->Effect.runSync
            todoItems->Dict.set(
              id,
              {...row, status: Failed, retryCount: row.retryCount + 1},
            )
            None
          }
          commandJson->Option.forEach(
            commandJson => {
              let msg: Reventless.Message.commandJson = {
                id: targetId,
                meta: makeMeta(),
                commandJson,
              }
              let _ = commands->Array.push(msg)
            },
          )
        | None => () // Skip — process returned None
        }
      })
    })

    if commands->Array.length > 0 {
      try await publishJsons(commands) catch {
      | exn =>
        let errMsg =
          exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        EffectLogger.logError(
          ~comp=`AutomationSlice(${Spec.name})`,
          `failed to publish commands: ${errMsg}`,
        )->Effect.runSync
        // Mark items as Failed for retry
        pending->Array.forEach(((id, row)) => {
          switch todoItems->Dict.get(id) {
          | Some(current) if current.status == Processing =>
            todoItems->Dict.set(
              id,
              {...row, status: Failed, retryCount: row.retryCount + 1},
            )
          | _ => ()
          }
        })
      }
    }
  }
}
