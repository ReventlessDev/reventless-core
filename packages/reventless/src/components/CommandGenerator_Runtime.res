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
  type publish = ReventlessSpec.CommandTopic.publish<Spec.Id.t, Spec.command>

  let generateCommand: publish => commandGenerator = publish =>
    async payload => {
      let msgId = Message.uuid()
      let id = payload.arguments.id->Spec.Id.makeFromString
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
      let decoded =
        payload.arguments
        ->Js.Json.stringifyAny // FIXME: find another way to transform a Js.t into Js.Json.t
        ->Belt.Option.flatMap(jsonString => jsonString->Js.Json.parseExn->Js.Json.decodeObject)
      let params = switch decoded {
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
      let decoded =
        params
        ->Js.Json.array
        ->Behaviour.resolverConfig.commandDecoder
      let command = switch decoded {
      | Belt.Result.Ok(command) => command
      | Error(err) =>
        Js.Exn.raiseError(
          `Error: Couldn't decode ${params
            ->Belt.Array.map(Js.Json.stringify)
            ->Js.Array2.joinWith(", ")}->Message.stringify: ${err
            ->Js.Json.stringifyAny
            ->Belt.Option.getExn}`,
        )
      }
      let command' = {
        {Message.id, meta, command}
      }
      await publish(command')
      meta.msgId
    }
}
