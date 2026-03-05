S.enableJson()
// AutomationSlice callback — implements the TODO list pattern.
//
// Phase 1 (collect/resolve): updates the in-memory TODO list from events
// Phase 2 (process): issues commands for pending items via publishJsons

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

  /** The in-memory TODO list — maps item ID to row. */
  let todoItems: ref<Dict.t<todoRow>>

  /** Phase 1: update TODO list from a batch of events. */
  let phase1: array<Spec.DcbEventLogSpec.event> => unit

  /** Phase 2: process all pending items, publishing commands via publishJsons. */
  let phase2: ReventlessInfra.CommandTopic.publishJsons => promise<unit>
}

module Make = (Spec: Reventless.AutomationSlice.Spec): (T with module Spec = Spec) => {
  module Spec = Spec

  let todoItems: ref<Dict.t<todoRow>> = ref(Dict.make())

  let now = () => Date.make()->Date.toISOString

  let makeMeta = (): Reventless.Message.meta => {
    service: `AutomationSlice:${Spec.name}`,
    time: now(),
    ip: "",
    user: "",
    msgId: Uuid.v4(),
    correlationId: "",
  }

  let phase1 = (events: array<Spec.DcbEventLogSpec.event>) => {
    events->Array.forEach(event => {
      // Collect new TODO items
      Spec.collect(event)->Array.forEach(((id, item)) => {
        switch todoItems.contents->Dict.get(id) {
        | Some(_) => () // Already exists — skip (idempotent)
        | None =>
          let row: todoRow = {
            item: item->S.reverseConvertToJsonOrThrow(Spec.todoItemSchema),
            status: Pending,
            createdAt: now(),
            retryCount: 0,
          }
          todoItems.contents->Dict.set(id, row)
        }
      })

      // Resolve completed items
      switch Spec.resolve(event) {
      | Some(id) =>
        todoItems.contents
        ->Dict.get(id)
        ->Option.forEach(row => {
          todoItems.contents->Dict.set(id, {...row, status: Completed, completedAt: now()})
        })
      | None => ()
      }
    })
  }

  let phase2 = async (publishJsons: ReventlessInfra.CommandTopic.publishJsons) => {
    let pending =
      todoItems.contents
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
        switch Spec.process(id, item) {
        | Some((targetId, command)) =>
          todoItems.contents->Dict.set(id, {...row, status: Processing, processedAt: now()})
          let commandJson = try command
          ->S.reverseConvertToJsonOrThrow(Spec.commandSchema)
          ->Some catch {
          | exn =>
            let errMsg =
              exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
            Effect.logError(
              `AutomationSlice(${Spec.name}): failed to encode command: ${errMsg}`,
            )->Effect.runSync
            todoItems.contents->Dict.set(
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
        Effect.logError(
          `AutomationSlice(${Spec.name}): failed to publish commands: ${errMsg}`,
        )->Effect.runSync
        // Mark items as Failed for retry
        pending->Array.forEach(((id, row)) => {
          switch todoItems.contents->Dict.get(id) {
          | Some(current) if current.status == Processing =>
            todoItems.contents->Dict.set(
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
