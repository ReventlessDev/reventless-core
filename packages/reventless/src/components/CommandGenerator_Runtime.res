type arguments = {id: string}
type meta = {ip: array<string>, user: string}
type payload = {
  command: string,
  arguments: arguments,
  meta: meta,
}
type commandGenerator = payload => Js.Promise.t<string>

module Make = (
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
) => {
  type publishJsons = ReventlessSpec.CommandTopic.publishJsons

  let generateCommand: publishJsons => commandGenerator = publishJsons =>
    async payload => {
      let msgId = Message.uuid()
      let id = payload.arguments.id
      let meta = {
        {
          Message.service: Spec.name,
          ip: payload.meta.ip->Js.Array.shift->Belt.Option.getWithDefault(""),
          user: payload.meta.user,
          time: Message.nowAsISOString(),
          msgId,
          correlationId: msgId,
        }
      }
      let argumentsJson =
        payload.arguments
        ->Js.Json.stringifyAny // FIXME: find another way to transform a Js.t into Js.Json.t
        ->Belt.Option.flatMap(jsonString => jsonString->Js.Json.parseExn->Js.Json.decodeObject)
      let params = switch argumentsJson {
      | Some(obj) => obj->Js.Dict.values
      | None =>
        Js.Exn.raiseError(
          "Couldn't decode:" ++
          payload.arguments
          ->Js.Json.stringifyAny
          ->Belt.Option.getWithDefault("<payload.arguments>"),
        )
      }
      params[0] = Js.Json.string(payload.command)
      let commandJson = params->Js.Json.array
      Js.log2("CommandGenerator: generated command:", commandJson)
      let decodedCommand = commandJson->Behaviour.resolverConfig.commandDecoder
      switch decodedCommand {
      | Belt.Result.Ok(_) =>
        await publishJsons([{id, meta, commandJson, delay: None}])
        meta.msgId
      | Error(err) =>
        Js.Exn.raiseError(
          `Error: Couldn't decode ${params
            ->Belt.Array.map(Js.Json.stringify)
            ->Js.Array2.joinWith(", ")}: ${err
            ->Js.Json.stringifyAny
            ->Belt.Option.getExn}`,
        )
      }
    }
}
