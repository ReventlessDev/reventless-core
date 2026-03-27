module type Spec = {
  let publishJsons: CommandGenerator.publishJsons
}

module type T = {
  let generateCommand: CommandGenerator.commandGenerator
}

let makeGenerateCommand = (
  ~publishJsons: CommandGenerator.publishJsons,
  ~serviceName: string,
  ~commandSchema: S.t<unknown>,
  ~stripIdFromParams: bool=true,
): CommandGenerator.commandGenerator => {
  (payload: CommandGenerator.payload) =>
    Effect.sync(() => {
      let msgId = Message.uuid()
      let id = payload.arguments.id
      let meta = {
        {
          Message.service: serviceName,
          ip: payload.meta.ip->Array.shift->Option.getOr(""),
          user: payload.meta.user,
          time: Message.nowAsISOString(),
          msgId,
          correlationId: msgId,
        }
      }
      let params = switch payload.arguments
      ->JSON.stringifyAny
      ->Option.flatMap(jsonString => jsonString->JSON.parseOrThrow->JSON.Decode.object) {
      | Some(obj) => {
          if stripIdFromParams {
            obj->Dict.delete("id")
          }
          obj->Dict.toArray
        }
      | None =>
        JsError.throwWithMessage(
          "Couldn't decode:" ++
          payload.arguments
          ->JSON.stringifyAny
          ->Option.getOr("<payload.arguments>"),
        )
      }
      let commandStr = JSON.Encode.string(payload.command)
      let commandJson = switch params->Array.length {
      | 0 => commandStr
      | _ => [("TAG", commandStr)]->Array.concat(params)->Dict.fromArray->JSON.Encode.object
      }
      (meta, commandJson, id)
    })
    ->Effect.tap(((_, commandJson, _)) =>
      Effect.logInfo(
        "CommandGenerator: generated command: " ++ commandJson->JSON.stringify,
      )
    )
    ->Effect.flatMap(((meta, commandJson, id)) => {
      switch commandJson->Message.decode(commandSchema) {
      | _ =>
        Effect.promise(() => {
          publishJsons([{id, meta, commandJson}])
        })->Effect.map(_ => meta.msgId)
      | exception err =>
        JsError.throwWithMessage(
          `Error: Couldn't decode ${commandJson->JSON.stringify}: ${err
            ->JSON.stringifyAny
            ->Option.getOrThrow}`,
        )
      }
    })
}

module Make = (
  Spec: Spec,
  AggregateSpec: Reventless.Aggregate.Spec,
): T => {
  let generateCommand = makeGenerateCommand(
    ~publishJsons=Spec.publishJsons,
    ~serviceName=AggregateSpec.name,
    ~commandSchema=AggregateSpec.commandSchema->S.castToUnknown,
  )
}
