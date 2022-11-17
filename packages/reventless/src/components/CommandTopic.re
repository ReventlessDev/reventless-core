open ReventlessSpec.Adapter;

let componentType = ComponentType.CommandTopic;

type outputs = {. "resources": array(resource)};

type publish('id, 'command) =
  (. Message.command'('id, 'command)) => Js.Promise.t(unit);
type publishJsons = (. array(Message.commandJson)) => Js.Promise.t(unit);

exception NotPublishedToConnector(Js.Promise.error);

module type Spec = {
  module Id: ReventlessSpec.Id.T;

  [@decco]
  type command;
};

type topicItem('command) = {
  command: 'command,
  reference: string,
};

type commandsHandler('command) =
  (. array(topicItem('command))) =>
  Js.Promise.t(array(Belt.Result.t(string, string)));

module type T = {
  module Spec: Spec;

  type nonrec commandsHandler =
    commandsHandler(Message.command'(Spec.Id.t, Spec.command));
  type t;

  let make:
    (
      ~name: string,
      ~commandsHandler: commandsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);

  let publish: Component.t(t, outputs) => publish(Spec.Id.t, Spec.command);
  let publishJsons: Component.t(t, outputs) => publishJsons;
};

module Adapter = {
  type connector = {
    resources: array(resource),
    publish: publishJsons,
  };
  type connectorMaker =
    (
      ~name: string,
      ~handleCommands: commandsHandler(Js.Json.t),
      ~memorySize: int,
      ~timeout: int,
      ~opts: Pulumi.CustomResourceOptions.t,
      ~resources: resources
    ) =>
    connector;

  module type Connector = {let make: connectorMaker;};

  type remoteConnector = {remotePublish: publishJsons};
  type remoteConnectorMaker = (~resource: resource) => remoteConnector;

  module type RemoteConnector = {let make: remoteConnectorMaker;};
};

module Make =
       (Spec: Spec, Connector: Adapter.Connector)
       : (T with module Spec = Spec) => {
  module Spec = Spec;

  type nonrec commandsHandler =
    commandsHandler(Message.command'(Spec.Id.t, Spec.command));
  type t;

  type constructed;
  type construct =
    (Component.t(t, outputs), string, commandsHandler, resources) =>
    constructed;

  type nonrec publish = publish(Spec.Id.t, Spec.command);

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~commandsHandler: commandsHandler,
      ~resources: resources
    ) =>
    Component.t(t, outputs) =
    "default";

  [@bs.obj]
  external makeOutputs: (~resources: array(resource)) => outputs = "";

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
  [@bs.set]
  external setPublishJsons: (Component.t(t, outputs), publishJsons) => unit =
    "publishJsons";
  [@bs.get]
  external publishJsons: Component.t(t, outputs) => publishJsons =
    "publishJsons";

  let publishJsonsFn = connector =>
    (. jsons) => {
      connector.Adapter.publish(. jsons)
      |> Js.Promise.catch(e => {
           Js.log2(
             "CommandTopic: Couldn't publish commands:",
             jsons->Belt.Array.map(commandJson =>
               commandJson->Message.commandJson_encode->Js.Json.stringify
             ),
           );
           NotPublishedToConnector(e)->Js.Promise.reject;
         })
      |> Js.Promise.then_(_ =>
           Js.log2(
             "CommandTopic: Published commands:",
             jsons->Belt.Array.map(commandJson =>
               commandJson->Message.commandJson_encode->Js.Json.stringify
             ),
           )
           ->Js.Promise.resolve
         );
    };

  let publishFn = connector =>
    (. command': Message.command'(Spec.Id.t, Spec.command)) => {
      let commandJson = {
        Message.id: command'.id->Spec.Id.toString,
        meta: command'.meta,
        commandJson: command'.command->Spec.command_encode,
        delay: None,
      };
      connector->publishJsonsFn(. [|commandJson|]);
    };

  let handleCommands = commandsHandler =>
    (. jsonItems) => {
      Js.log2(
        "starting CommandTopic.handleCommands. Command count:",
        jsonItems->Belt.Array.size,
      );
      let topicItems =
        jsonItems->Belt.Array.keepMap(({reference, command: json}) =>
          switch (
            json
            |> Message.command'_decode(Spec.Id.t_decode, Spec.command_decode)
          ) {
          | Belt_Result.Ok(command') => Some({reference, command: command'})
          | Belt_Result.Error(err) =>
            let commandStr = json->Js.Json.stringify;
            let message = err.message;
            Js.log(
              {j|CommandTopic: Error: Couldn't decode command $commandStr: $message|j},
            );
            None;
          }
        );
      commandsHandler(. topicItems)
      |> Js.Promise.then_(res => {
           Js.log("finished CommandTopic.handleCommands");
           res->Js.Promise.resolve;
         })
      |> Js.Promise.catch(err => {
           let error = err->Util.Error.ofPromise##message;
           Js.Exn.raiseError(
             {j|CommandTopic.handleCommand: Error: Couldn't handle commands: $error|j},
           );
         });
    };

  let construct =
      (~memorySize, ~timeout, self, name, commandsHandler, resources) => {
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
        ~resources,
      );
    resources->Util_CommandTopic.setConnectorResource(
      connector.resources[0],
      name,
    );

    self->setPublish(connector->publishFn);
    self->setPublishJsons(connector->publishJsonsFn);

    makeOutputs(~resources=connector.resources)->setOutputs(self, _);
  };

  let make:
    (
      ~name: string,
      ~commandsHandler: commandsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs) =
    (
      ~name,
      ~commandsHandler,
      ~memorySize=1024,
      ~timeout=30,
      ~opts=?,
      ~resources,
      _,
    ) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct=construct(~memorySize, ~timeout),
        ~opts,
        ~commandsHandler,
        ~resources,
      );
    };
};
