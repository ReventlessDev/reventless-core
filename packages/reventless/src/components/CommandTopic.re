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

module type T = {
  type id;
  type command;
  type commandsHandler = Message.commandsHandler(id, command);
  type nonrec t = t(id, command);

  let make:
    (
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

module type Connector = {
  let make:
    (
      ~name: string,
      ~handleCommands: (. array(Js.Json.t)) => Js.Promise.t(unit),
      ~memorySize: int,
      ~timeout: int,
      ~opts: Pulumi.CustomResourceOptions.t
    ) =>
    connector;
};

module Make =
       (Config: Config.T, Service: Message.Service, Connector: Connector)
       : (T with type id = Service.id and type command := Service.command) => {
  type id = Service.id;
  type command = Service.command;
  type commandsHandler = Message.commandsHandler(id, command);

  type nonrec t = t(id, command);

  type constructed;
  type construct = (t, string, commandsHandler) => constructed;

  type nonrec publish = publish(Message.command'(id, command));

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

  [@bs.send] external registerOutputs: (t, outputs) => constructed = "";
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
          Service.id_encode,
          Service.command_encode,
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

  let logCommand' = (idx, count, command': Message.command'(id, command)) => {
    let id = command'.id;
    let command: array(string) =
      command'.command->Service.command_encode->Obj.magic;
    let commandName = command[0];
    let commandStr =
      command'
      |> Message.command'_encode(Service.id_encode, Service.command_encode)
      |> Js.Json.stringify;
    let idx = idx + 1;
    Js.log(
      {j|CommandTopic: handling command $idx/$count: $commandName($id)  complete command: $commandStr|j},
    );
  };

  let groupCommandsById:
    array((id, Message.command'(id, command))) =>
    array((id, array(Message.command'(id, command)))) =
    commands => {
      let (ids, commands) = commands->Belt.Array.unzip;
      ids
      ->Belt.Set.fromArray(~id=(module Belt.Id.MakeComparable(Service.Id)))
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
          |> Message.command'_decode(
               Service.id_decode,
               Service.command_decode,
             )
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
        ~name,
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
      ~commandsHandler: commandsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    t =
    (~commandsHandler, ~memorySize=256, ~timeout=30, ~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Service.name->ComponentType.name(componentType),
        ~construct=construct(~memorySize, ~timeout),
        ~opts,
        ~commandsHandler,
      );
    };
};