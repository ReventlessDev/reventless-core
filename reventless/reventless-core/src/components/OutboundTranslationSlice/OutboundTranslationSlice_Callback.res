S.enableJson()
// OutboundTranslationSlice callback — implements the tracked external call pattern.
//
// Phase 1 (collect): updates the in-memory TODO list from events (no resolve)
// Phase 2 (translate): calls Spec.translate for each pending item individually

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

module type T = {
  module Spec: Reventless.OutboundTranslationSlice.Spec

  /** The in-memory TODO list -- maps item ID to row. */
  let todoItems: ref<Dict.t<todoRow>>

  /** Phase 1: update TODO list from a batch of events (collect only, no resolve). */
  let phase1: array<Spec.consumedEvent> => unit

  /** Phase 2: translate all pending items, optionally publishing commands via publishJsons. */
  let phase2: ReventlessInfra.CommandTopic.publishJsons => promise<unit>
}

module Make = (Spec: Reventless.OutboundTranslationSlice.Spec): (T with module Spec = Spec) => {
  module Spec = Spec

  let todoItems: ref<Dict.t<todoRow>> = ref(Dict.make())

  let now = () => Date.make()->Date.toISOString

  let makeMeta = (): Reventless.Message.meta => {
    service: `OutboundTranslationSlice:${Spec.name}`,
    time: now(),
    ip: "",
    user: "",
    msgId: Uuid.v4(),
    correlationId: "",
  }

  let phase1 = (events: array<Spec.consumedEvent>) => {
    events->Array.forEach(event => {
      // Collect new outbound items
      Spec.collect(event)->Array.forEach(((id, item)) => {
        switch todoItems.contents->Dict.get(id) {
        | Some(_) => () // Already exists -- skip (idempotent)
        | None =>
          let row: todoRow = {
            item: item->S.reverseConvertToJsonOrThrow(Spec.outboundItemSchema),
            status: Pending,
            createdAt: now(),
            retryCount: 0,
          }
          todoItems.contents->Dict.set(id, row)
        }
      })
    })
  }

  let phase2 = async (publishJsons: ReventlessInfra.CommandTopic.publishJsons) => {
    let pending =
      todoItems.contents
      ->Dict.toArray
      ->Array.filter(((_, row)) =>
        row.status == Pending || (row.status == Failed && row.retryCount < Spec.maxRetries)
      )

    // Process each item individually -- each translate call is independent
    let _ = await pending->Array.reduce(Promise.resolve(), async (prev, (id, row)) => {
      let _ = await prev

      let item = try row.item->S.parseJsonOrThrow(Spec.outboundItemSchema)->Some catch {
      | exn =>
        let errMsg =
          exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(
          `OutboundTranslationSlice(${Spec.name}): failed to decode outboundItem: ${errMsg}`,
        )->Effect.runSync
        None
      }

      switch item {
      | None => ()
      | Some(item) =>
        todoItems.contents->Dict.set(id, {...row, status: Processing, processedAt: now()})

        let result = try await Spec.translate(id, item) catch {
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
          ->S.reverseConvertToJsonOrThrow(Spec.inboundCommandSchema)
          ->Some catch {
          | exn =>
            let errMsg =
              exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
            Effect.logError(
              `OutboundTranslationSlice(${Spec.name}): failed to encode inbound command: ${errMsg}`,
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
              todoItems.contents->Dict.set(id, {...row, status: Completed, completedAt: now()})
            } catch {
            | exn =>
              let errMsg =
                exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
              Effect.logError(
                `OutboundTranslationSlice(${Spec.name}): failed to publish command: ${errMsg}`,
              )->Effect.runSync
              todoItems.contents->Dict.set(
                id,
                {...row, status: Failed, retryCount: row.retryCount + 1},
              )
            }
          | None =>
            todoItems.contents->Dict.set(
              id,
              {...row, status: Failed, retryCount: row.retryCount + 1},
            )
          }

        | Ok(None) =>
          // Fire-and-forget: no command to publish
          todoItems.contents->Dict.set(id, {...row, status: Completed, completedAt: now()})

        | Error(msg) =>
          todoItems.contents->Dict.set(
            id,
            {...row, status: Failed, retryCount: row.retryCount + 1, lastError: msg},
          )
        }
      }
    })
  }
}
