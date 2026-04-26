S.enableJson()
// AutomationSlice callback — implements the TODO list pattern with mixed-source
// dispatch (Plan 04).
//
// Phase 1 (collect/resolve): for each event JSON, look up its source by
// `meta.service`, decode against the matching `Mapping.sourceEventSchema`, and
// run the mapping's `collect`/`resolve`. Multiple mappings may share a source
// name; all matching mappings run.
//
// Phase 2 (process): walk pending TODO items; for each, run the producing
// mapping's `toTags` to validate that DCB tag fields are populated, then call
// `Automation.process` to construct the command, encode, and publish via
// `publishJsons`. `toTags` failures log a warning and mark the item Failed
// (incrementing retryCount) — same retry path as encode/publish failures.

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
  /** Name of the mapping that created this TODO item — used in phase2 to find
      the right `toTags` function. */
  sourceName: string,
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
  let phase2: (
    ReventlessInfra.CommandTopic.publishJsons,
    Reventless.AutomationSlice.context,
  ) => promise<unit>
}

module Make = (
  Spec: Reventless.AutomationSlice.Spec,
  Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
  Mappings: Reventless.AutomationSlice.Mappings with module Target := Spec,
): (T with module Spec = Spec and module Automation := Automation) => {
  module Spec = Spec
  module Automation = Automation

  let todoItems: Dict.t<todoRow> = Dict.make()

  let now = () => Date.make()->Date.toISOString

  let makeMeta = (): Reventless.Message.meta => {
    service: `AutomationSlice:${Spec.name}`,
    time: now(),
    ip: "",
    user: "",
    msgId: Uuid.v4(),
    correlationId: "",
  }

  // Per-source erased dispatch — pre-compile decoders once at module init.
  type dispatch = {
    sourceName: string,
    handle: (JSON.t, Reventless.AutomationSlice.context) => unit,
    validateTags: (Spec.todoItem, Reventless.AutomationSlice.context) => result<unit, string>,
  }

  let dispatches: array<dispatch> = Mappings.mappings->Array.map((
    module(M: Mappings.Mapping),
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
              sourceName: M.sourceName,
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
    let validateTags = (item: Spec.todoItem, ctx: Reventless.AutomationSlice.context) =>
      switch M.toTags(item, ctx) {
      | Ok(_tagSet) => Ok()
      | Error(msg) => Error(msg)
      }
    {sourceName: M.sourceName, handle, validateTags}
  })

  let findDispatch = (sourceName: string): option<dispatch> =>
    dispatches->Array.find(d => d.sourceName == sourceName)

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

  let phase2 = async (
    publishJsons: ReventlessInfra.CommandTopic.publishJsons,
    ctx: Reventless.AutomationSlice.context,
  ) => {
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
        Effect.logError(
          `AutomationSlice(${Spec.name}): failed to decode todoItem: ${errMsg}`,
        )->Effect.runSync
        None
      }

      item->Option.forEach(item => {
        // Tag validation — locate the producing mapping by sourceName recorded in row.
        let tagsResult = switch findDispatch(row.sourceName) {
        | Some(d) => d.validateTags(item, ctx)
        | None =>
          // Should not happen — sourceName is always set by phase1 from a registered mapping.
          Error(`unknown sourceName "${row.sourceName}" — mapping not found`)
        }

        switch tagsResult {
        | Error(msg) =>
          Effect.logWarning(
            `AutomationSlice(${Spec.name}): toTags failed for item ${id}: ${msg}`,
          )->Effect.runSync
          todoItems->Dict.set(
            id,
            {...row, status: Failed, retryCount: row.retryCount + 1},
          )
        | Ok() =>
          switch Automation.process(id, item) {
          | Some((targetId, command)) =>
            todoItems->Dict.set(id, {...row, status: Processing, processedAt: now()})
            let commandJson = try command
            ->S.reverseConvertToJsonOrThrow(Spec.commandSchema)
            ->Some catch {
            | exn =>
              let errMsg =
                exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
              Effect.logError(
                `AutomationSlice(${Spec.name}): failed to encode command: ${errMsg}`,
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
        }
      })
    })

    if commands->Array.length > 0 {
      try await publishJsons(commands) catch {
      | exn =>
        let errMsg =
          exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(
          `AutomationSlice(${Spec.name}): failed to publish commands: ${errMsg}`,
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
