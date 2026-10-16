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
  /** Failed and will be tried again. */
  | Failed
  /** Failed for the last time — the retry budget is spent and no pass will pick
      this row up again. Distinct from `Failed` because the two are opposite
      instructions to whoever is reading: wait, or intervene. */
  | Abandoned

@schema
type todoRow = {
  item: JSON.t,
  status: todoStatus,
  createdAt: string,
  processedAt?: string,
  completedAt?: string,
  retryCount: int,
  /** The ceiling `retryCount` is racing, copied from the Spec when the row is
      created. Optional because rows written before this field existed are
      rehydrated through `S.parseOrThrow`, and a required field would fail that
      decode — silently, since the restore swallows it per row. */
  maxRetries?: int,
}

/** The item schema seen through the `JSON.t` the row actually stores.

    `item` holds `Spec.todoItemSchema`-encoded JSON, so the item schema already
    describes the stored value exactly — only the ReScript types disagree. */
external itemAsJson: S.t<'item> => S.t<JSON.t> = "%identity"

/**
The row schema as the API describes it: `item` carried by the slice's own item
schema instead of as opaque JSON.

`todoRowSchema` types `item` as `JSON.t`, which the schema→GraphQL IR can only
classify as `Unknown` — and `Unknown` renders as `String!`. The field then
serves a stored object through a String, which fails at execution ("String
cannot represent value: { … }") the moment a client selects it. Describing the
item shape gives the field a real object type instead.

Shape only: never encode or parse a row with this. The runtime field is `JSON.t`
and the identity cast above would have `S.parseOrThrow` hand back an item where
the row's own code expects JSON.
*/
let todoRowSchemaFor = (itemSchema: S.t<'item>): S.t<todoRow> =>
  S.schema(s => {
    item: s.matches(itemSchema->itemAsJson),
    status: s.matches(todoStatusSchema),
    createdAt: s.matches(S.string),
    processedAt: ?s.matches(S.option(S.string)),
    completedAt: ?s.matches(S.option(S.string)),
    retryCount: s.matches(S.int),
    maxRetries: ?s.matches(S.option(S.int)),
  })

/**
The runtime protocol between a built callback and whoever drives it — the same
arrangement as `OutboundTranslationSlice_Callback`, and for the same reason. The
AWS entry point builds callbacks dynamically and has to ascribe a structural type
at the JS boundary; pointing that ascription at these aliases is what keeps it
from becoming an unreconcilable second declaration of the shape.

Unlike outbound, phase 1 here takes *raw* envelope JSONs: the callback routes by
`meta.service` and unwraps `{id, meta, event}` itself, per-source, through the
registered Mappings.
*/
type phase1 = (array<JSON.t>, Reventless.AutomationSlice.context) => unit

/** Phase 2: process all pending items, publishing commands. */
type phase2 = ReventlessInfra.CommandTopic.publishJsons => promise<unit>

/** The whole protocol as a value, for a driver that holds a built callback and
    knows nothing of the Spec behind it. */
type runtime = {
  todoItems: Dict.t<todoRow>,
  phase1: phase1,
  phase2: phase2,
  /** The slice's schedules, by key: what its schedules store holds. */
  schedules: Dict.t<AutomationSlice_Schedules.row>,
  /** What phase 1 changed in `schedules` since the last call, for the platform to
      follow once the rows are stored. */
  takeScheduleChanges: unit => array<AutomationSlice_Schedules.platformChange>,
  /** Folds the given events' `reschedule` into empty rows, in order: a rebuild. */
  rebuildSchedules: array<JSON.t> => unit,
}

/** A tick as the runtime receives an event: an envelope from the `Clock`
    source, recorded at the scheduled time. */
let tickEvent = (~key, ~at) =>
  JSON.Encode.object(
    Dict.fromArray([
      ("id", key->JSON.Encode.string),
      (
        "meta",
        {
          ...Message.generateMeta(~service=Reventless.Clock.name),
          time: at->Date.fromTime->Date.toISOString,
        }->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema),
      ),
      (
        "event",
        Reventless.Clock.Tick({key, at})->Reventless.Util_Sury.toJson(Reventless.Clock.eventSchema),
      ),
    ]),
  )

module type T = {
  module Spec: Reventless.AutomationSlice.Spec
  module Automation: Reventless.AutomationSlice.Automation with module Spec := Spec

  /** The in-memory TODO list — maps item ID to row. */
  let todoItems: Dict.t<todoRow>

  /** Phase 1: update TODO list from a batch of raw event JSONs. Internally
      decodes per-source via the registered Mappings. */
  let phase1: phase1

  /** Phase 2: process all pending items, publishing commands via publishJsons. */
  let phase2: phase2

  let schedules: Dict.t<AutomationSlice_Schedules.row>
  let takeScheduleChanges: unit => array<AutomationSlice_Schedules.platformChange>
  let rebuildSchedules: array<JSON.t> => unit
}

module Make = (
  Spec: Reventless.AutomationSlice.Spec,
  Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
): (T with module Spec = Spec and module Automation := Automation) => {
  module Spec = Spec
  module Automation = Automation

  let todoItems: Dict.t<todoRow> = Dict.make()
  let schedules: Dict.t<AutomationSlice_Schedules.row> = Dict.make()
  let scheduleChanges: ref<array<AutomationSlice_Schedules.platformChange>> = ref([])

  let takeScheduleChanges = () => {
    let changes = scheduleChanges.contents
    scheduleChanges := []
    changes
  }

  // Only a slice that maps the Clock can receive the ticks a schedule sends.
  let readsClock =
    Automation.mappings->Array.some((module(M: Automation.Mapping)) =>
      M.sourceName == Reventless.Clock.name
    )

  let now = () => Date.make()->Date.toISOString

  // Root meta for commands emitted by this AutomationSlice. The triggering
  // event's meta is not currently threaded from phase1 → phase2 (todoItems
  // only carries `item` data), so causation across the automation hop is
  // lost — emitted commands are roots of a fresh correlation chain. If we
  // later thread source meta through todoItems, switch to deriveMeta.
  // `service` names the command's TARGET, matching the API path
  // (`CommandGenerator_Callback` passes `~serviceName=AggregateSpec.name`). An
  // aggregate derives its event meta from the command's, and ReadModel /
  // AutomationSlice callbacks dispatch mappings on `meta.service` — so naming
  // the slice here makes the target's own events unmatchable, silently.
  let makeMeta = (): Reventless.Message.meta => Message.generateMeta(~service=Spec.targetName)

  /** How long a row may stay `Processing` before its command is sent again. */
  let processingTimeoutMs =
    15. *. 60. *. 1000.

  /** Record a failed attempt. The row is marked `Abandoned` at the moment the
      budget runs out rather than being left to fall out of the next pass's
      filter, so a reader never has to compare `retryCount` against a constant
      that lives only in this Spec. */
  let afterFailedAttempt = (row: todoRow): todoRow => {
    let retryCount = row.retryCount + 1
    {...row, status: retryCount >= Spec.maxRetries ? Abandoned : Failed, retryCount}
  }

  /** The command a slice wants published now that this item will never be
      processed again, if it wants one. The row is `Abandoned` either way. */
  let abandonmentCommand = (~id: string, ~row: todoRow): option<Reventless.Message.commandJson> =>
    switch row.item->Reventless.Util_Sury.fromJson(Spec.todoItemSchema) {
    | item =>
      Automation.onExhausted(id, item)->Option.flatMap(((targetId, command)) =>
        switch command->Reventless.Util_Sury.toJson(Spec.commandSchema) {
        | commandJson => Some({Reventless.Message.id: targetId, meta: makeMeta(), commandJson})
        | exception _ =>
          EffectLogger.logError(
            ~comp=`AutomationSlice(${Spec.name})`,
            `retries exhausted for ${id}, and the abandonment command could not be encoded`,
          )->Effect.runSync
          None
        }
      )
    | exception _ =>
      EffectLogger.logError(
        ~comp=`AutomationSlice(${Spec.name})`,
        `retries exhausted for ${id}, and its item could not be decoded to announce it`,
      )->Effect.runSync
      None
    }

  module Route = AutomationSlice_Route.Make(Spec, Automation)

  // An event's recorded time, from its envelope's ISO `meta.time`.
  let recordedAtOf = time =>
    switch Date.fromString(time)->Date.getTime {
    | millis if Float.isNaN(millis) => None
    | millis => Some(millis)
    }

  let apply = ({collected, resolved}: AutomationSlice_Route.routed<Spec.todoItem>) => {
    // Collect — append new items keyed by ID; first writer wins (idempotent).
    collected->Array.forEach(((id, item)) => {
      switch todoItems->Dict.get(id) {
      | Some(_) => () // Already exists — skip
      | None =>
        let row: todoRow = {
          item: item->Reventless.Util_Sury.toJson(Spec.todoItemSchema),
          status: Pending,
          createdAt: now(),
          retryCount: 0,
          maxRetries: Spec.maxRetries,
        }
        todoItems->Dict.set(id, row)
      }
    })
    // Resolve — mark a pending item as completed.
    resolved->Option.forEach(id =>
      todoItems
      ->Dict.get(id)
      ->Option.forEach(row => {
        todoItems->Dict.set(id, {...row, status: Completed, completedAt: now()})
      })
    )
  }

  let reschedule = (
    routed: array<AutomationSlice_Route.routed<Spec.todoItem>>,
    ~setBy,
    ~recordedAt,
  ) =>
    routed->Array.forEach(r =>
      r.rescheduled->Array.forEach(change =>
        if !readsClock {
          EffectLogger.logError(
            ~comp=`AutomationSlice(${Spec.name})`,
            `a mapping changed a schedule, but no mapping reads the Clock, so no tick would reach the slice; the change is skipped`,
          )->Effect.runSync
        } else {
          switch schedules->AutomationSlice_Schedules.apply(change, ~setBy, ~recordedAt) {
          | Ok(platformChange) =>
            scheduleChanges := scheduleChanges.contents->Array.concat([platformChange])
          | Error(message) =>
            EffectLogger.logError(
              ~comp=`AutomationSlice(${Spec.name})`,
              `${message}; the change is skipped`,
            )->Effect.runSync
          }
        }
      )
    )

  let phase1 = (events: array<JSON.t>, sliceCtx: Reventless.AutomationSlice.context) => {
    events->Array.forEach(json => {
      let context = json->Message.decode(Reventless.Message.contextSchema)
      let ctx = switch recordedAtOf(context.meta.time) {
      | Some(recordedAt) => {...sliceCtx, recordedAt}
      | None => sliceCtx
      }
      let sourceName = context.meta.service
      // Events arrive as `{id, meta, event}` envelopes (see Message.composeEventJson').
      // Per-mapping decoders work on the inner `event` payload (TAG + fields at
      // the top level), not the wrapper.
      let eventPayload = switch json->JSON.Decode.object {
      | Some(dict) => dict->Dict.get("event")->Option.getOr(json)
      | None => json
      }
      // Multiple mappings can share a sourceName; all matching dispatches run.
      let routed = Route.route(eventPayload, ~sourceName, ~sourceId=context.id, ctx)
      routed->Array.forEach(apply)
      reschedule(
        routed,
        ~setBy=context.meta.msgId,
        ~recordedAt=ctx.recordedAt->Option.getOr(Date.now()),
      )

      // A tick's envelope is addressed by its key.
      if sourceName == Reventless.Clock.name {
        schedules->AutomationSlice_Schedules.fired(~key=context.id)
      }
    })
  }

  let rebuildSchedules = (events: array<JSON.t>) => {
    schedules->Dict.keysToArray->Array.forEach(key => schedules->Dict.delete(key))
    events->Array.forEach(json => {
      let context = json->Message.decode(Reventless.Message.contextSchema)
      let eventPayload = switch json->JSON.Decode.object {
      | Some(dict) => dict->Dict.get("event")->Option.getOr(json)
      | None => json
      }
      let recordedAt = recordedAtOf(context.meta.time)->Option.getOr(Date.now())
      Route.route(
        eventPayload,
        ~sourceName=context.meta.service,
        ~sourceId=context.id,
        {environment: "", platformName: "", pluginName: "", sliceName: Spec.name, recordedAt},
      )->reschedule(~setBy=context.meta.msgId, ~recordedAt)
    })
    scheduleChanges := []
  }

  let phase2 = async (publishJsons: ReventlessInfra.CommandTopic.publishJsons) => {
    let currentTime = await Clock.currentTimeMillis->Effect.runPromise
    // A `Failed` row at or past the ceiling is one an older build left stranded,
    // or one whose Spec lowered `maxRetries` under it. Either way it is abandoned
    // in fact, so say so rather than letting it sit in a status that promises a
    // retry no pass will make.
    let newlyAbandoned: array<string> = []
    // A command published but never answered leaves its row `Processing`. After
    // the timeout that counts as a failed attempt, so this pass sends it again
    // while the budget lasts.
    todoItems
    ->Dict.toArray
    ->Array.forEach(((id, row)) =>
      switch (row.status, row.processedAt->Option.map(t => Date.fromString(t)->Date.getTime)) {
      | (Processing, Some(processedAt)) if currentTime -. processedAt >= processingTimeoutMs =>
        let updated = row->afterFailedAttempt
        todoItems->Dict.set(id, updated)
        if updated.status == Abandoned {
          newlyAbandoned->Array.push(id)
        }
      | _ => ()
      }
    )
    todoItems
    ->Dict.toArray
    ->Array.forEach(((id, row)) =>
      if row.status == Failed && row.retryCount >= Spec.maxRetries {
        todoItems->Dict.set(id, {...row, status: Abandoned})
        newlyAbandoned->Array.push(id)
      }
    )

    let pending =
      todoItems
      ->Dict.toArray
      ->Array.filter(((_, row)) =>
        row.status == Pending || (row.status == Failed && row.retryCount < Spec.maxRetries)
      )

    let commands = []

    pending->Array.forEach(((id, row)) => {
      let item = try row.item->Reventless.Util_Sury.fromJson(Spec.todoItemSchema)->Some catch {
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
        switch Automation.process(id, item, ~now=currentTime) {
        | Some((targetId, command)) =>
          todoItems->Dict.set(id, {...row, status: Processing, processedAt: now()})
          let commandJson = try command
          ->Reventless.Util_Sury.toJson(Spec.commandSchema)
          ->Some catch {
          | exn =>
            let errMsg =
              exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
            EffectLogger.logError(
              ~comp=`AutomationSlice(${Spec.name})`,
              `failed to encode command: ${errMsg}`,
            )->Effect.runSync
            let updated = row->afterFailedAttempt
            todoItems->Dict.set(id, updated)
            if updated.status == Abandoned {
              newlyAbandoned->Array.push(id)
            }
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
            let updated = row->afterFailedAttempt
            todoItems->Dict.set(id, updated)
            if updated.status == Abandoned {
              newlyAbandoned->Array.push(id)
            }
          | _ => ()
          }
        })
      }
    }

    // Announced after the batch, so a publish failure above has already had its
    // say on which rows ran out of budget. A failure here cannot mark anything for
    // retry — the budget is what ran out — so the rows stay `Abandoned` regardless.
    let abandonmentCommands =
      newlyAbandoned->Array.filterMap(id =>
        todoItems->Dict.get(id)->Option.flatMap(row => abandonmentCommand(~id, ~row))
      )
    if abandonmentCommands->Array.length > 0 {
      try await publishJsons(abandonmentCommands) catch {
      | exn =>
        let errMsg =
          exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        EffectLogger.logError(
          ~comp=`AutomationSlice(${Spec.name})`,
          `failed to publish abandonment commands: ${errMsg}`,
        )->Effect.runSync
      }
    }
  }
}
