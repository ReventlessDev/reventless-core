open ReventlessSpec.Adapter

let componentType = ComponentType.CommandGenerator

type outputs = {resources: array<resource>}

type t
type component = ReventlessSpec.Component.t<t, outputs>

module type Spec = {
  module Id: ReventlessSpec.Id.T

  let name: string

  @decco
  type command

  @decco
  type event

  @decco
  type error
}

module type T = {
  module Spec: Spec

  type publish = Message.commandHandler<Spec.Id.t, Spec.command>

  let make: (
    ~name: string,
    ~publish: publish,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

type arguments = {id: string}
type meta = {ip: array<string>, user: string}
type payload = {
  command: string,
  arguments: arguments,
  meta: meta,
}
type commandGenerator = payload => Js.Promise.t<string>

module Adapter = {
  type resolvers = {resources: array<resource>}
  type resolversMaker<'api> = (
    ~name: string,
    ~api: 'api,
    ~fields: array<string>,
    ~commandGenerator: commandGenerator,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => resolvers

  module type Resolvers = {
    type api

    let make: resolversMaker<api>
  }
}

module Make = (
  Config: Config.T,
  Spec: Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
  Resolvers: Adapter.Resolvers with type api := Config.api,
): (T with module Spec = Spec) => {
  module Spec = Spec

  type api = Config.api

  type publish = Message.commandHandler<Spec.Id.t, Spec.command>

  type constructed
  type construct = (component, string, api, publish) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
    ~api: api,
    ~publish: publish,
  ) => component = "default"

  @obj external makeOutputs: (~resources: array<resource>) => outputs = ""

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  //[@send] external setOutputs: (t, outputs) => unit = "setOutputs";

  let generateCommand: publish => commandGenerator = publish => {
    let fn = async payload => {
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
    fn
  }

  let construct = (self, name, api, commandHandler) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let resolvers = Resolvers.make(
      ~name=name->ComponentType.name(componentType),
      ~api,
      ~fields=Behaviour.resolverConfig.fields,
      ~commandGenerator=generateCommand(commandHandler),
      ~opts,
    )

    let outputs = makeOutputs(~resources=resolvers.resources)
    //self->setOutputs(outputs); // NOTE: creates circular reference (promise leaks)
    self->registerOutputs(outputs)
  }

  let make = (~name, ~publish, ~opts=?) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts,
      ~api=Config.api,
      ~publish,
    )
}
