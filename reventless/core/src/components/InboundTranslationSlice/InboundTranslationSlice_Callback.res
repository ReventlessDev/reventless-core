S.enableJson()
// InboundTranslationSlice callback — receives external input and translates to commands.
//
// Maintains an audit log QueryDb and delegates translation to Translation.translate.

@schema
type auditStatus =
  | Success
  | Failure

@schema
type auditRow = {
  input: string,
  status: auditStatus,
  targetIds?: array<string>,
  commandCount?: int,
  error?: string,
  receivedAt: string,
}

module type T = {
  module Spec: Reventless.InboundTranslationSlice.Spec
  module Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec

  /** The audit log -- maps request ID to audit row. */
  let auditLog: Dict.t<auditRow>

  /** Receive external input, translate it, and publish commands. */
  let receive: (
    ReventlessInfra.CommandTopic.publishJsons,
    JSON.t,
  ) => promise<result<array<string>, string>>
}

module Make = (
  Spec: Reventless.InboundTranslationSlice.Spec,
  Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
): (T with module Spec = Spec and module Translation := Translation) => {
  module Spec = Spec
  module Translation = Translation

  let auditLog: Dict.t<auditRow> = Dict.make()

  let now = () => Date.make()->Date.toISOString

  // InboundTranslationSlice ingests external (non-Reventless) messages — there's
  // no upstream Reventless meta to derive from, so emitted commands are roots
  // of a fresh correlation chain. `traceparent` populated from an inbound HTTP
  // header would need to be threaded in here by the API/ingress adapter.
  let makeMeta = (): Reventless.Message.meta =>
    Message.generateMeta(~service=`InboundTranslationSlice:${Spec.name}`)

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
      auditLog->Dict.set(
        requestId,
        {
          input: inputJson->JSON.stringify,
          status: Failure,
          error: msg,
          receivedAt: now(),
        },
      )
      Error(msg)

    | Ok(input) =>
      switch Translation.translate(input) {
      | Ok(pairs) =>
        if pairs->Array.length === 0 {
          auditLog->Dict.set(
            requestId,
            {
              input: inputJson->JSON.stringify,
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
                let commandJson = cmd->JSON.stringifyAny->Option.getOrThrow->JSON.parseOrThrow
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
                EffectLogger.logError(
                  ~comp=`InboundTranslationSlice(${Spec.name})`,
                  `failed to encode command: ${errMsg}`,
                )->Effect.runSync
                encodeError := Some("failed to encode command")
              }
            }
          })

          switch encodeError.contents {
          | Some(msg) =>
            auditLog->Dict.set(
              requestId,
              {
                input: inputJson->JSON.stringify,
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
              auditLog->Dict.set(
                requestId,
                {
                  input: inputJson->JSON.stringify,
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
              auditLog->Dict.set(
                requestId,
                {
                  input: inputJson->JSON.stringify,
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
        auditLog->Dict.set(
          requestId,
          {
            input: inputJson->JSON.stringify,
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
