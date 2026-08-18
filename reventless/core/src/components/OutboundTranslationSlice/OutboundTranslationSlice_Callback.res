// OutboundTranslationSlice callback — implements the tracked external call pattern.
//
// Phase 1 (collect): updates the in-memory TODO list from events (no resolve)
// Phase 2 (translate): calls Translation.translate for each pending item individually

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
  lastError?: string,
}

/** The item schema seen through the `JSON.t` the row actually stores.

    `item` holds `Spec.outboundItemSchema`-encoded JSON, so the item schema
    already describes the stored value exactly — only the ReScript types
    disagree. */
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
    lastError: ?s.matches(S.option(S.string)),
  })

/**
The runtime protocol between a built callback and whoever drives it.

Defined here, once, and referenced by every party — `module type T` below, the
in-process builder, and the AWS entry point, which cannot name `T` because it
builds callbacks dynamically per `HANDLER_CONFIG` entry and must ascribe a
structural type at the JS boundary.

That ascription is the reason these aliases exist. A driver that restates the
shape instead of referencing it becomes a second source of truth that the
compiler cannot reconcile with this one: when `phase1` gained its `sourceId`,
the AWS entry point kept passing bare events and nothing complained, because its
hand-written copy was internally consistent. The mismatch surfaced only at
runtime, as `undefined` destructured from a tuple that was never a tuple.
*/
type phase1<'event> = array<(string, 'event)> => unit

/** Phase 2: translate all pending items, optionally publishing commands.

    `~capabilities` is supplied by whoever drives the callback — the in-process
    builder or the Lambda entry point — because that is the layer that knows what
    the platform provisioned. It arrives here rather than at `Make` so the
    functor stays a pure function of the Spec, appliable before a runtime exists. */
type phase2 = (
  ReventlessInfra.CommandTopic.publishJsons,
  ~capabilities: Reventless.Capabilities.t,
) => promise<unit>

/** The whole protocol as a value — what a driver holding a built callback needs,
    with no knowledge of the Spec it was built from. */
type runtime<'event> = {
  todoItems: Dict.t<todoRow>,
  phase1: phase1<'event>,
  phase2: phase2,
}

module type T = {
  module Spec: Reventless.OutboundTranslationSlice.Spec
  module Translation: Reventless.OutboundTranslationSlice.Translation with module Spec := Spec

  /** The in-memory TODO list -- maps item ID to row. */
  let todoItems: Dict.t<todoRow>

  /** Phase 1: update TODO list from a batch of `(sourceId, event)` pairs
      (collect only, no resolve). `sourceId` is the envelope id of the entity the
      event was published for. */
  let phase1: phase1<Spec.consumedEvent>

  /** Phase 2: translate all pending items, optionally publishing commands via publishJsons. */
  let phase2: phase2
}

module Make = (
  Spec: Reventless.OutboundTranslationSlice.Spec,
  Translation: Reventless.OutboundTranslationSlice.Translation with module Spec := Spec,
): (T with module Spec = Spec and module Translation := Translation) => {
  module Spec = Spec
  module Translation = Translation

  let todoItems: Dict.t<todoRow> = Dict.make()

  let now = () => Date.make()->Date.toISOString

  // Root meta for messages emitted by this OutboundTranslationSlice. Source-event
  // meta is not threaded from phase1 → phase2 today, so causation across the
  // translation hop is not preserved. If sources later carry meta into todoItems,
  // switch to Message.deriveMeta.
  //
  // `service` names the command's TARGET, matching what the API path does
  // (`CommandGenerator_Callback` passes `~serviceName=AggregateSpec.name`). It is
  // load-bearing rather than descriptive: an aggregate derives its event's meta
  // from the command's, and ReadModel/AutomationSlice callbacks dispatch mappings
  // on `meta.service`. Naming the slice here instead makes the aggregate emit an
  // event no mapping for that aggregate matches — projected as zero actions, with
  // no error. Falls back to the slice's own name only when there is no target, in
  // which case the command goes to the plugin's DCB topic and nothing dispatches
  // on it.
  let makeMeta = (): Reventless.Message.meta =>
    Message.generateMeta(
      ~service=Spec.targetName->Option.getOr(`OutboundTranslationSlice:${Spec.name}`),
    )

  let phase1 = (events: array<(string, Spec.consumedEvent)>) => {
    events->Array.forEach(((sourceId, event)) => {
      // Collect new outbound items
      Translation.collect(event, ~sourceId)->Array.forEach(((id, item)) => {
        switch todoItems->Dict.get(id) {
        | Some(_) => () // Already exists -- skip (idempotent)
        | None =>
          let row: todoRow = {
            item: item->Reventless.Util_Sury.toJson(Spec.outboundItemSchema),
            status: Pending,
            createdAt: now(),
            retryCount: 0,
          }
          todoItems->Dict.set(id, row)
        }
      })
    })
  }

  let phase2 = async (
    publishJsons: ReventlessInfra.CommandTopic.publishJsons,
    ~capabilities: Reventless.Capabilities.t,
  ) => {
    let pending =
      todoItems
      ->Dict.toArray
      ->Array.filter(((_, row)) =>
        row.status == Pending || (row.status == Failed && row.retryCount < Spec.maxRetries)
      )

    // Process each item individually -- each translate call is independent
    let _ = await pending->Array.reduce(Promise.resolve(), async (prev, (id, row)) => {
      let _ = await prev

      let item = try row.item->Reventless.Util_Sury.fromJson(Spec.outboundItemSchema)->Some catch {
      | exn =>
        let errMsg =
          exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        EffectLogger.logError(
          ~comp=`OutboundTranslationSlice(${Spec.name})`,
          `failed to decode outboundItem: ${errMsg}`,
        )->Effect.runSync
        None
      }

      switch item {
      | None => ()
      | Some(item) =>
        todoItems->Dict.set(id, {...row, status: Processing, processedAt: now()})

        let result = try await Translation.translate(id, item, ~capabilities) catch {
        | exn =>
          let msg =
            exn
            ->JsExn.fromException
            ->Option.flatMap(JsExn.message)
            ->Option.getOr("unknown error")
          Error(msg)
        }

        switch result {
        | Ok(Some((targetId, cmd))) =>
          // Encode command and publish
          let commandJson = try cmd
          ->Reventless.Util_Sury.toJson(Spec.inboundCommandSchema)
          ->Some catch {
          | exn =>
            let errMsg =
              exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
            EffectLogger.logError(
              ~comp=`OutboundTranslationSlice(${Spec.name})`,
              `failed to encode inbound command: ${errMsg}`,
            )->Effect.runSync
            None
          }

          switch commandJson {
          | Some(commandJson) =>
            try {
              let msg: Reventless.Message.commandJson = {
                id: targetId,
                meta: makeMeta(),
                commandJson,
              }
              await publishJsons([msg])
              todoItems->Dict.set(id, {...row, status: Completed, completedAt: now()})
            } catch {
            | exn =>
              let errMsg =
                exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
              EffectLogger.logError(
                ~comp=`OutboundTranslationSlice(${Spec.name})`,
                `failed to publish command: ${errMsg}`,
              )->Effect.runSync
              todoItems->Dict.set(
                id,
                {...row, status: Failed, retryCount: row.retryCount + 1},
              )
            }
          | None =>
            todoItems->Dict.set(
              id,
              {...row, status: Failed, retryCount: row.retryCount + 1},
            )
          }

        | Ok(None) =>
          // Fire-and-forget: no command to publish
          todoItems->Dict.set(id, {...row, status: Completed, completedAt: now()})

        | Error(msg) =>
          todoItems->Dict.set(
            id,
            {...row, status: Failed, retryCount: row.retryCount + 1, lastError: msg},
          )
        }
      }
    })
  }
}
