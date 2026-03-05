module type Spec = {
  let publishJsons: CommandGenerator.publishJsons
}

module type T = {
  let generateCommand: CommandGenerator.commandGenerator
}

module Make = (
  Spec: Spec,
  AggregateSpec: Reventless.Aggregate.Spec,
  Behavior: Behavior.T with module Spec := AggregateSpec,
): T => {
  let generateCommand = (payload: CommandGenerator.payload) =>
    Effect.sync(() => {
      let msgId = Message.uuid()
      let id = payload.arguments.id
      let meta = {
        {
          Message.service: AggregateSpec.name,
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
          obj->Dict.delete("id")
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
      switch commandJson->Message.decode(Behavior.resolverConfig.commandSchema) {
      | _ =>
        Effect.promise(() => {
          Spec.publishJsons([{id, meta, commandJson}])
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
