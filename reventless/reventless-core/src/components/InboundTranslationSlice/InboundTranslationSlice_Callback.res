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
  targetId?: string,
  error?: string,
  receivedAt: string,
}

module type T = {
  module Spec: Reventless.InboundTranslationSlice.Spec

  /** The audit log -- maps request ID to audit row. */
  let auditLog: ref<Dict.t<auditRow>>

  /** Receive external input, translate it, and publish a command. */
  let receive: (
    ReventlessInfra.CommandTopic.publishJsons,
    JSON.t,
  ) => promise<result<string, string>>
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

  let receive = async (publishJsons: ReventlessInfra.CommandTopic.publishJsons, inputJson: JSON.t) => {
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
      auditLog.contents->Dict.set(requestId, {
        input: inputJson,
        status: Failure,
        error: msg,
        receivedAt: now(),
      })
      Error(msg)

    | Ok(input) =>
      switch Spec.translate(input) {
      | Ok((targetId, cmd)) =>
        let commandJson = try
          cmd->S.reverseConvertToJsonOrThrow(Spec.commandSchema)->Some
        catch {
        | exn =>
          Logger.error(
            ~loc=__LOC__,
            `InboundTranslationSlice(${Spec.name}): failed to encode command`,
            exn,
          )
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
            auditLog.contents->Dict.set(requestId, {
              input: inputJson,
              status: Success,
              targetId,
              receivedAt: now(),
            })
            Ok(targetId)
          } catch {
          | exn =>
            let msg =
              exn
              ->JsExn.fromException
              ->Option.flatMap(JsExn.message)
              ->Option.getOr("publish failed")
            auditLog.contents->Dict.set(requestId, {
              input: inputJson,
              status: Failure,
              error: msg,
              receivedAt: now(),
            })
            Error(msg)
          }

        | None =>
          let msg = "failed to encode command"
          auditLog.contents->Dict.set(requestId, {
            input: inputJson,
            status: Failure,
            error: msg,
            receivedAt: now(),
          })
          Error(msg)
        }

      | Error(msg) =>
        auditLog.contents->Dict.set(requestId, {
          input: inputJson,
          status: Failure,
          error: msg,
          receivedAt: now(),
        })
        Error(msg)
      }
    }
  }
}
