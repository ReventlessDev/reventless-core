module type Spec = {
  let publishJsons: CommandGenerator.publishJsons
}

module type T = {
  let generateCommand: CommandGenerator.commandGenerator
}

module Make = (
  Spec: Spec,
  AggregateSpec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := AggregateSpec,
): T => {
  let generateCommand = async (payload: CommandGenerator.payload) => {
    let msgId = Message.uuid()
    let id = payload.arguments.id
    let meta = {
      {
        Message.service: AggregateSpec.name,
        ip: payload.meta.ip->Js.Array.shift->Option.getOr(""),
        user: payload.meta.user,
        time: Message.nowAsISOString(),
        msgId,
        correlationId: msgId,
      }
    }
    let argumentsJson =
      payload.arguments
      ->Js.Json.stringifyAny // FIXME: find another way to transform a Js.t into Js.Json.t
      ->Option.flatMap(jsonString => jsonString->Js.Json.parseExn->Js.Json.decodeObject)
    let params = switch argumentsJson {
    | Some(obj) => obj->Js.Dict.values
    | None =>
      Js.Exn.raiseError(
        "Couldn't decode:" ++
        payload.arguments
        ->Js.Json.stringifyAny
        ->Option.getOr("<payload.arguments>"),
      )
    }
    let commandStr = Js.Json.string(payload.command)
    let commandJson = switch params[1] {
    | Some(params) => [("TAG", commandStr), ("_0", params)]->Js.Dict.fromArray->Js.Json.object_
    | _ => commandStr
    }
    Js.log2("CommandGenerator: generated command:", commandJson)
    switch commandJson->Message.decode(Behaviour.resolverConfig.commandSchema) {
    | _ =>
      await Spec.publishJsons([{id, meta, commandJson, delay: None}])
      meta.msgId
    | exception err =>
      Js.Exn.raiseError(
        `Error: Couldn't decode ${commandJson->Js.Json.stringify}: ${err
          ->Js.Json.stringifyAny
          ->Option.getExn}`,
      )
    }
  }
}
