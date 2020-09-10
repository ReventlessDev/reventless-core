let componentType = ComponentType.CommandTopic;

type publish('data) = (. 'data) => Js.Promise.t(unit);

type functions('id, 'command) = {
  .
  "publish": publish(Message.command'('id, 'command)),
};

type outputs = {. "connector": Adapter.resource};
external toOutputs: functions('id, 'command) => outputs = "%identity";

type t('id, 'command) = functions('id, 'command);

exception NotPublishedToConnector(Js.Promise.error);

module type Spec = {
  module Id: Id.T;

  [@decco]
  type command;
};

module type T = {
  module Spec: Spec;

  type commandsHandler = Message.commandsHandler(Spec.Id.t, Spec.command);
  type nonrec t = t(Spec.Id.t, Spec.command);

  let make:
    (
      ~name: string,
      ~commandsHandler: commandsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    t;
};

type connector = {
  resource: Adapter.resource,
  publish: publish(Js.Json.t),
};
type connectorMaker =
  (
    ~name: string,
    ~handleCommands: (. array(Js.Json.t)) => Js.Promise.t(unit),
    ~memorySize: int,
    ~timeout: int,
    ~opts: Pulumi.CustomResourceOptions.t
  ) =>
  connector;

module type Connector = {let make: connectorMaker;};

module Make =
       (Spec: Spec, Connector: Connector)
       : (T with module Spec := Spec) => {
  module Spec = Spec;

  type commandsHandler = Message.commandsHandler(Spec.Id.t, Spec.command);

  type nonrec t = t(Spec.Id.t, Spec.command);

  type constructed;
  type construct = (t, string, commandsHandler) => constructed;

  type nonrec publish = publish(Message.command'(Spec.Id.t, Spec.command));

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~commandsHandler: commandsHandler
    ) =>
    t =
    "default";

  [@bs.obj]
  external makeOutputs: (~connector: Adapter.resource) => outputs = "";

  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set] external setPublish: (t, publish) => unit = "publish";

  let publish = connector =>
    (. command') => {
      let json =
        Message.command'_encode(
          Spec.Id.t_encode,
          Spec.command_encode,
          command',
        );
      let resourceName = connector.resource##name->Pulumi.Output.get;

      connector.publish(. json)
      |> Js.Promise.catch(e => {
           Js.log(
             {j|CommandTopic: Couldn't publish command $json to $resourceName|j},
           );
           NotPublishedToConnector(e)->Js.Promise.reject;
         })
      |> Js.Promise.then_(_ =>
           Js.log(
             {j|CommandTopic: Published command: $json to $resourceName|j},
           )
           ->Js.Promise.resolve
         );
    };

  let logCommand' =
      (idx, count, command': Message.command'(Spec.Id.t, Spec.command)) => {
    let id = command'.id;
    let command: array(string) =
      command'.command->Spec.command_encode->Obj.magic;
    let commandName = command[0];
    let commandStr =
      command'
      |> Message.command'_encode(Spec.Id.t_encode, Spec.command_encode)
      |> Js.Json.stringify;
    let idx = idx + 1;
    Js.log(
      {j|CommandTopic: handling command $idx/$count: $commandName($id)  complete command: $commandStr|j},
    );
  };

  let groupCommandsById:
    array((Spec.Id.t, Message.command'(Spec.Id.t, Spec.command))) =>
    array((Spec.Id.t, array(Message.command'(Spec.Id.t, Spec.command)))) =
    commands => {
      let (ids, commands) = commands->Belt.Array.unzip;
      ids
      ->Belt.Set.fromArray(~id=(module Belt.Id.MakeComparable(Spec.Id)))
      ->Belt.Set.toArray
      ->Belt.Array.map(id =>
          (id, commands->Belt.Array.keep(command' => command'.id == id))
        );
    };

  let handleCommands = commandsHandler =>
    (. jsons) =>
      jsons->Belt.Array.keepMap(json =>
        switch (
          json
          |> Message.command'_decode(Spec.Id.t_decode, Spec.command_decode)
        ) {
        | Belt_Result.Ok(command') => Some((command'.id, command'))
        | Belt_Result.Error(err) =>
          let commandStr = json->Js.Json.stringify;
          let message = err.message;
          Js.log(
            {j|CommandTopic: Error: Couldn't decode command $commandStr: $message|j},
          );
          None;
        }
      )
      |> groupCommandsById
      |> Array.map(((id, commands')) => {
           let commandCount = commands' |> Array.length;
           commands'
           |> Array.mapi((idx, command') =>
                logCommand'(idx, commands' |> Array.length, command')
              )
           |> ignore;
           commandsHandler(. id, commands')
           |> Js.Promise.catch(err =>
                failwith(
                  {j|CommandTopic.handleCommand: Error: Couldn't handle $commandCount command(s) for id $id: $err|j},
                )
                |> Js.Promise.reject
              );
         })
      |> Js.Promise.all
      |> Js.Promise.then_(_ => Js.Promise.resolve());

  let construct = (~memorySize, ~timeout, self, name, commandsHandler) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let connector =
      Connector.make(
        ~name=name->ComponentType.name(componentType),
        ~handleCommands=commandsHandler->handleCommands,
        ~memorySize,
        ~timeout,
        ~opts,
      );

    self->setPublish(connector->publish);

    connector.resource->makeOutputs(~connector=_) |> self->setOutputs;
  };

  let make:
    (
      ~name: string,
      ~commandsHandler: commandsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    t =
    (~name, ~commandsHandler, ~memorySize=256, ~timeout=30, ~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct=construct(~memorySize, ~timeout),
        ~opts,
        ~commandsHandler,
      );
    };
};
