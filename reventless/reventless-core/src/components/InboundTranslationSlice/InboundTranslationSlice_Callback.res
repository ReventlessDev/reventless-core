S.enableJson()
// InboundTranslationSlice callback — receives external input and translates to commands.
//
// Maintains an audit log QueryDb and delegates translation to Spec.translate.

@schema
type auditStatus =
  | Success
  | Failure

@schema
type auditRow = {
  input: JSON.t,
  status: auditStatus,
  targetIds?: array<string>,
  commandCount?: int,
  error?: string,
  receivedAt: string,
}

module type T = {
  module Spec: Reventless.InboundTranslationSlice.Spec

  /** The audit log -- maps request ID to audit row. */
  let auditLog: ref<Dict.t<auditRow>>

  /** Receive external input, translate it, and publish commands. */
  let receive: (
    ReventlessInfra.CommandTopic.publishJsons,
    JSON.t,
  ) => promise<result<array<string>, string>>
}

module Make = (Spec: Reventless.InboundTranslationSlice.Spec): (T with module Spec = Spec) => {
  module Spec = Spec

  let auditLog: ref<Dict.t<auditRow>> = ref(Dict.make())

  let now = () => Date.make()->Date.toISOString

  let makeMeta = (): Reventless.Message.meta => {
    service: `InboundTranslationSlice:${Spec.name}`,
    time: now(),
    ip: "",
    user: "",
    msgId: Uuid.v4(),
    correlationId: "",
  }

  let receive = async (
    publishJsons: ReventlessInfra.CommandTopic.publishJsons,
    inputJson: JSON.t,
  ) => {
    let requestId = Uuid.v4()

    // Parse the external input
    let input = try inputJson->S.parseOrThrow(Spec.externalInputSchema)->Ok catch {
    | exn =>
      let msg =
        exn
        ->JsExn.fromException
        ->Option.flatMap(JsExn.message)
        ->Option.getOr("invalid input")
      Error(msg)
    }

    switch input {
    | Error(msg) =>
      auditLog.contents->Dict.set(
        requestId,
        {
          input: inputJson,
          status: Failure,
          error: msg,
          receivedAt: now(),
        },
      )
      Error(msg)

    | Ok(input) =>
      switch Spec.translate(input) {
      | Ok(pairs) =>
        if pairs->Array.length === 0 {
          auditLog.contents->Dict.set(
            requestId,
            {
              input: inputJson,
              status: Success,
              targetIds: [],
              commandCount: 0,
              receivedAt: now(),
            },
          )
          Ok([])
        } else {
          // Encode all commands; abort on first encoding failure
          let msgs = ref([])
          let encodeError = ref(None)
          pairs->Array.forEach(pair => {
            let (targetId, cmd) = pair
            if encodeError.contents->Option.isNone {
              try {
                let commandJson = cmd->S.reverseConvertToJsonOrThrow(Spec.commandSchema)
                let msg: Reventless.Message.commandJson = {
                  id: targetId,
                  meta: makeMeta(),
                  commandJson,
                }
                msgs.contents = msgs.contents->Array.concat([msg])
              } catch {
              | exn =>
                let errMsg =
                  exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
                Effect.logError(
                  `InboundTranslationSlice(${Spec.name}): failed to encode command: ${errMsg}`,
                )->Effect.runSync
                encodeError := Some("failed to encode command")
              }
            }
          })

          switch encodeError.contents {
          | Some(msg) =>
            auditLog.contents->Dict.set(
              requestId,
              {
                input: inputJson,
                status: Failure,
                error: msg,
                receivedAt: now(),
              },
            )
            Error(msg)
          | None =>
            try {
              await publishJsons(msgs.contents)
              let targetIds = pairs->Array.map(pair => {
                let (targetId, _) = pair
                targetId
              })
              auditLog.contents->Dict.set(
                requestId,
                {
                  input: inputJson,
                  status: Success,
                  targetIds,
                  commandCount: pairs->Array.length,
                  receivedAt: now(),
                },
              )
              Ok(targetIds)
            } catch {
            | exn =>
              let msg =
                exn
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("publish failed")
              auditLog.contents->Dict.set(
                requestId,
                {
                  input: inputJson,
                  status: Failure,
                  error: msg,
                  receivedAt: now(),
                },
              )
              Error(msg)
            }
          }
        }

      | Error(msg) =>
        auditLog.contents->Dict.set(
          requestId,
          {
            input: inputJson,
            status: Failure,
            error: msg,
            receivedAt: now(),
          },
        )
        Error(msg)
      }
    }
  }
}
