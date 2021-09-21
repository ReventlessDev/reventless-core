open ReventlessSpec.Adapter;

let componentType = ComponentType.CommandTopic;

type outputs = {. "connector": resource};

type publish('id, 'command) =
  (. Message.command'('id, 'command)) => Js.Promise.t(unit);

exception NotPublishedToConnector(Js.Promise.error);

module type Spec = {
  module Id: ReventlessSpec.Id.T;

  [@decco]
  type command;
};

module type T = {
  module Spec: Spec;

  type commandsHandler = Message.commandsHandler(Spec.Id.t, Spec.command);
  type t;

  let make:
    (
      ~name: string,
      ~commandsHandler: commandsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    Component.t(t, outputs);

  let publish: Component.t(t, outputs) => publish(Spec.Id.t, Spec.command);
};

module Adapter = {
  type connector = {
    resource,
    publish: (. string, Message.meta, Js.Json.t) => Js.Promise.t(unit),
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
};

module Make =
       (Spec: Spec, Connector: Adapter.Connector)
       : (T with module Spec = Spec) => {
  module Spec = Spec;

  type commandsHandler = Message.commandsHandler(Spec.Id.t, Spec.command);

  type t;

  type constructed;
  type construct =
    (Component.t(t, outputs), string, commandsHandler) => constructed;

  type nonrec publish = publish(Spec.Id.t, Spec.command);

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~commandsHandler: commandsHandler
    ) =>
    Component.t(t, outputs) =
    "default";

  [@bs.obj] external makeOutputs: (~connector: resource) => outputs = "";

  [@bs.send]
  external registerOutputs: (Component.t(t, outputs), outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (Component.t(t, outputs), outputs) => unit =
    "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set]
  external setPublish: (Component.t(t, outputs), publish) => unit = "publish";
  [@bs.get] external publish: Component.t(t, outputs) => publish = "publish";

  let publishFn = connector =>
    (. command') => {
      let json =
        Message.command'_encode(
          Spec.Id.t_encode,
          Spec.command_encode,
          command',
        );
      let jsonStr = json->Js.Json.stringify;
      let resourceName = connector.Adapter.resource##name->Pulumi.Output.get;

      connector.publish(. command'.id->Spec.Id.toString, command'.meta, json)
      |> Js.Promise.catch(e => {
           Js.log(
             {j|CommandTopic: Couldn't publish command $jsonStr to $resourceName|j},
           );
           NotPublishedToConnector(e)->Js.Promise.reject;
         })
      |> Js.Promise.then_(_ =>
           Js.log(
             {j|CommandTopic: Published command: $jsonStr to $resourceName|j},
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
    (. jsons) => {
      Js.log("starting CommandTopic.handleCommands");
      jsons
      ->Belt.Array.keepMap(json =>
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
      ->groupCommandsById
      ->Belt.Array.map(((id, commands')) => {
          let commandCount = commands'->Belt.Array.length;
          commands'
          ->Belt.Array.mapWithIndex((idx, command') =>
              logCommand'(idx, commands'->Belt.Array.length, command')
            )
          ->ignore;
          commandsHandler(. id, commands')
          |> Js.Promise.then_(res => {
               Js.log({j|finished commandsHandler for id $id|j});
               res->Js.Promise.resolve;
             })
          |> Js.Promise.catch(err => {
               let error = err->AwsSdk.Error.ofPromise##message;
               Js.Exn.raiseError(
                 {j|CommandTopic.handleCommand: Error: Couldn't handle $commandCount command(s) for id $id: $error|j},
               );
             });
        })
      |> Js.Promise.all
      |> Js.Promise.then_(_ => {
           Js.log("finished CommandTopic.handleCommands");
           Js.Promise.resolve();
         });
    };

  let construct = (~memorySize, ~timeout, self, name, commandsHandler) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
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
    Util_CommandTopic.Deploytime.setConnectorResource(
      connector.resource,
      name,
    );

    self->setPublish(connector->publishFn);

    makeOutputs(~connector=connector.resource)->setOutputs(self, _);
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
    Component.t(t, outputs) =
    (~name, ~commandsHandler, ~memorySize=1024, ~timeout=30, ~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct=construct(~memorySize, ~timeout),
        ~opts,
        ~commandsHandler,
      );
    };
};
