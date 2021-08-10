open ReventlessSpec.Adapter;

let componentType = ComponentType.CommandGenerator;

type outputs = {. "resolvers": array(resource)};

module type Spec = {
  module Id: ReventlessSpec.Id.T;

  let name: string;

  [@decco]
  type command;

  [@decco]
  type event;

  [@decco]
  type error;
};

module type T = {
  module Spec: Spec;

  type commandHandler = Message.commandHandler(Spec.Id.t, Spec.command);

  type t;

  let make:
    (
      ~name: string,
      ~commandHandler: commandHandler,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    Component.t(t, outputs);
};

type payload = {
  .
  "command": string,
  "arguments": {. "id": string},
  "meta": {
    .
    "ip": array(string),
    "user": string,
  },
};
type commandGenerator = payload => Js.Promise.t(string);

module Adapter = {
  type resolvers = {resources: array(resource)};
  type resolversMaker('api) =
    (
      ~name: string,
      ~api: 'api,
      ~fields: array(string),
      ~commandGenerator: commandGenerator,
      ~opts: Pulumi.CustomResourceOptions.t
    ) =>
    resolvers;

  module type Resolvers = {
    type api;

    let make: resolversMaker(api);
  };
};

module Make =
       (
         Config: Config.T,
         Spec: Spec,
         Behaviour: Behaviour.T with module Spec := Spec,
         Resolvers: Adapter.Resolvers with type api := Config.api,
       )
       : (T with module Spec = Spec) => {
  module Spec = Spec;
  type t;

  type api = Config.api;

  type commandHandler = Message.commandHandler(Spec.Id.t, Spec.command);

  type constructed;
  type construct =
    (Component.t(t, outputs), string, api, commandHandler) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~api: api,
      ~commandHandler: commandHandler
    ) =>
    Component.t(t, outputs) =
    "default";

  [@bs.obj]
  external makeOutputs: (~resolvers: array(resource)) => outputs = "";

  [@bs.send]
  external registerOutputs: (Component.t(t, outputs), outputs) => constructed =
    "registerOutputs";
  //[@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";

  let generateCommand: commandHandler => commandGenerator =
    commandHandler => {
      let fn = payload => {
        let msgId = Message.uuid();
        let id = payload##arguments##id |> Spec.Id.makeFromString;
        let meta =
          Message.{
            service: Spec.name,
            ip:
              payload##meta##ip
              |> Js.Array.shift
              |> Js.Option.getWithDefault(""),
            user: payload##meta##user,
            time: Message.nowAsISOString(),
            msgId,
            correlationId: msgId,
          };
        let params =
          payload##arguments
          |> Message.stringify
          |> Js.Json.parseExn
          |> Js.Json.decodeObject
          |> (
            fun
            | Some(obj) => obj |> Js.Dict.values
            | None =>
              Js.Exn.raiseError(
                "Couldn't decode:" ++ (payload##arguments |> Message.stringify),
              )
          );
        params[0] = Js.Json.string(payload##command);
        let command =
          params
          |> Js.Json.array
          |> Behaviour.resolverConfig.commandDecoder
          |> (
            fun
            | Belt.Result.Ok(command) => command
            | Error(err) =>
              Js.Exn.raiseError(
                {j|Couldn't decode $params|>Message.stringify: $err|j},
              )
          );
        let command' = Message.{id, meta, command};
        commandHandler(. command')
        |> Js.Promise.then_(_ => Js.Promise.resolve(meta.msgId));
      };
      fn;
    };

  let construct = (self, name, api, commandHandler) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let resolvers =
      Resolvers.make(
        ~name,
        ~api,
        ~fields=Behaviour.resolverConfig.fields,
        ~commandGenerator=generateCommand(commandHandler),
        ~opts,
      );

    let outputs = makeOutputs(~resolvers=resolvers.resources);
    //self->setOutputs(outputs); // NOTE: creates circular reference (promise leaks)
    self->registerOutputs(outputs);
  };

  let make:
    (
      ~name: string,
      ~commandHandler: commandHandler,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    Component.t(t, outputs) =
    (~name, ~commandHandler, ~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=name->ComponentType.name(componentType),
        ~construct,
        ~opts,
        ~api=Config.api,
        ~commandHandler,
      );
    };
};
