let componentType = ComponentType.Plugin;

type outputs = {
  .
  "eventCollector": EventCollector.outputs,
  "extensionPoints": Js.Dict.t(ExtensionPoint.outputs),
  "extensions": Js.Dict.t(Extension.outputs),
  "services": Js.Dict.t(Service.outputs),
  "tasks": Js.Dict.t(Task.outputs),
  "eventMappers": Js.Dict.t(EventMapper.outputs),
  "resolvers": array(Adapter.resource),
  "heartbeat": Heartbeat.outputs,
};

type plugin; // TODO: rename to t - after refactoring

type maker =
  (
    ~name: string,
    ~version: string,
    ~timeout: int,
    ~extensionPointMakers: array(ExtensionPoint.maker),
    ~extensionMakers: array(Extension.maker),
    ~serviceMakers: array(Service.maker),
    ~taskMakers: array(Task.maker),
    ~eventMapperMakers: array(EventMapper.maker),
    ~scheduler: Scheduler.t,
    ~opts: Pulumi.ComponentResource.Options.t=?,
    unit
  ) =>
  Component.t(plugin, outputs);

module type T = {let make: maker;};

let toDict = els =>
  els->Belt.Array.map(el => (el##name, el))->Js.Dict.fromArray;

module Make = (EventCollectorAdapter: EventCollector.Connector) : T => {
  type constructed;
  type construct = (Component.t(plugin, outputs), string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    Component.t(plugin, outputs) =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~eventCollector: EventCollector.outputs,
      ~extensionPoints: Js.Dict.t(ExtensionPoint.outputs),
      ~extensions: Js.Dict.t(Extension.outputs),
      ~services: Js.Dict.t(Service.outputs),
      ~tasks: Js.Dict.t(Task.outputs),
      ~eventMappers: Js.Dict.t(EventMapper.outputs),
      ~resolvers: array(Adapter.resource),
      ~heartbeat: Heartbeat.outputs
    ) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs:
    (Component.t(plugin, outputs), outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (Component.t(plugin, outputs), outputs) => unit =
    "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  let construct =
      (
        ~version: string,
        ~timeout: int,
        ~extensionPointMakers: array(ExtensionPoint.maker),
        ~extensionMakers: array(Extension.maker),
        ~serviceMakers: array(Service.maker),
        ~taskMakers: array(Task.maker),
        ~eventMapperMakers: array(EventMapper.maker),
        ~scheduler: Scheduler.t,
        self,
        name,
      ) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let makeId = (name, version) => {j|$name@$version|j};
    let id = makeId(name, version);

    let services =
      serviceMakers->Belt.Array.map(serviceMaker =>
        serviceMaker(Some(opts))
      );
    let servicesOutputs = services->Component.extractMultipleOutputs;

    let queryCommandTopic =
      InterstackResourceQueryRuntime.commandTopicConnectorOfAllServicesExn(
        servicesOutputs->Interstack.mergeServices,
      );
    open Pulumi.StackReference.Infix;

    let corePluginCommandTopicId =
      Interstack.coreStackOutput->Pulumi.Output.apply(output =>
        output->Obj.magic
        -# "extensionPoints"
        -# PluginExtensionPointSpec.name
        -# "commandTopic"
        -# "connector"
        -# "id"
      );

    let queryExtensionPointCommandTopicId = name =>
      if (name == PluginExtensionPointSpec.name) {
        corePluginCommandTopicId->Pulumi.Output.get->Some->Js.Promise.resolve;
      } else {
        Some("NOT IMPLEMENTED YET !")
        ->Js.Promise.resolve; // TODO
      };

    let queryEventTopic = name =>
      if (name == PluginExtensionPointSpec.name) {
        Interstack.coreStackOutput->Pulumi.Output.apply(core =>
          core->Obj.magic
          -# "extensionPoints"
          -# PluginExtensionPointSpec.name
          -# "eventTopic"
          -# "publisher"
        );
      } else {
        InterstackResourceQueryDeploytime.eventTopicPublisherOfAllServicesExn(
          servicesOutputs,
          name,
        );
      };

    let extensionPoints =
      extensionPointMakers->Belt.Array.map(extensionPointMaker =>
        extensionPointMaker(
          ~queryCommandTopic,
          ~scheduler,
          ~opts=Some(opts),
          (),
        )
      );
    let extensionPointsOutputs =
      extensionPoints->Component.extractMultipleOutputs;

    let extensions =
      extensionMakers->Belt.Array.map(extensionMaker =>
        extensionMaker(
          ~queryCommandTopic,
          ~queryExtensionPointCommandTopicId,
          ~opts=Some(opts),
          (),
        )
      );
    let extensionsOutputs = extensions->Component.extractMultipleOutputs;

    let eventCollectorId: ref(Pulumi.Output.t(string)) =
      ref("NOT-SET"->Pulumi.Output.make);

    let extensionPointsConfig =
      extensionPointsOutputs->Belt.Array.map(extensionPoint =>
        {
          PluginSpec.name: extensionPoint##name,
          commandTopic:
            extensionPoint##commandTopic##connector##id->Pulumi.Output.get,
          eventTopic:
            extensionPoint##eventTopic##publisher##id->Pulumi.Output.get,
        }
      );
    let extensionsConfig =
      extensionsOutputs->Belt.Array.map(extension =>
        {
          PluginSpec.name: extension##name,
          eventCollector: (eventCollectorId^)->Pulumi.Output.get,
        }
      );

    let callHandler =
      fun
      | PluginExtensionPointSpec.ConnectPlugin(pluginSpec) => {
          /* TODO: actually connect given eventTopic to this Plugin.eventCollector*/

          // ExtensionPoint.EventTopic ----> Plugin.EventCollector

          // for every ExtensionPoint of the connected Plugin which has a realted Extension in this Plugin -> connect
          let connectToExtensionPoints =
            pluginSpec.extensionPoints
            ->Belt.Array.map(extensionPoint =>
                extensionsOutputs
                ->Belt.Array.getBy(extension =>
                    extension##name == extensionPoint.name
                  )
                ->Belt.Option.mapWithDefault(Js.Promise.resolve(), _extension =>
                    (eventCollectorId^)
                    ->Pulumi.Output.get
                    /* NOTE: should we raise an error to create a CloudWatchAlarm, when connecting doesn't work? */
                    /* TODO: connect extensionPoint##eventTopic to thisPlug's eventCollector */
                    ->Js.log2("TODO call awsSdk with:", _)
                    ->Js.Promise.resolve
                    /* END TODO */
                    ->Js.Promise.catch(
                        err =>
                          Js.log2(
                            "Could not connect Plugins "
                            ++ (pluginSpec.name ++ ":" ++ extensionPoint.name)
                            ++ "->"
                            ++ name
                            ++ ":",
                            err,
                          )
                          ->Js.Promise.resolve,
                        _,
                      )
                  )
              )
            ->Js.Promise.all
            ->Js.Promise.then_(_ => Js.Promise.resolve(), _);

          let connectToExtensions = {
            Js.Promise.resolve();
          };

          Js.Promise.all2((connectToExtensionPoints, connectToExtensions))
          ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
        }
      | _ => Js.Promise.resolve();

    module PluginExtensionMapping =
      ExtensionMapping.Make(
        PluginExtensionPointSpec,
        {
          open ExtensionMapping;
          module Aggregate = ExtensionMapping.NoAggregate;

          let mapIncomingEvent:
            ExtensionMapping.mapIncomingEvent(
              PluginExtensionPointSpec.event,
              Aggregate.Id.t,
              Aggregate.command,
              PluginExtensionPointSpec.command,
              PluginExtensionPointSpec.callCommand,
            ) =
            (eventId, event, _meta) =>
              switch (event) {
              | PluginExtensionPointSpec.UnknownPluginDetected
                  when eventId == id => [|
                  PublishExtensionPointCommand(
                    id,
                    PluginExtensionPointSpec.ConnectPlugin({
                      PluginSpec.name,
                      version,
                      extensionPoints: extensionPointsConfig,
                      extensions: extensionsConfig,
                    }),
                  ),
                |]
              | PluginConnected(pluginSpec) when eventId != id => [|
                  Call(callHandler, ConnectPlugin(pluginSpec)),
                |]
              | _ => [||]
              };

          let mapOutgoingEvent = (_id, _event, _meta) => [||];
        },
      );

    module PluginExtension = Extension.Make(PluginExtensionPointSpec);
    let pluginExtensionMaker =
      PluginExtension.make([|(module PluginExtensionMapping)|]);
    let pluginExtension =
      pluginExtensionMaker(
        ~queryCommandTopic,
        ~queryExtensionPointCommandTopicId,
        ~opts=Some(opts),
        (),
      );

    let allExtensionsOutputs =
      extensionsOutputs->Belt.Array.concat([|
        pluginExtension->Component.extractOutputs,
      |]);

    let queryQueryDb =
      InterstackResourceQueryRuntime.queryDbStorageOfAllServicesExn(
        servicesOutputs->Interstack.mergeServices,
      );

    let queryQueryDbDeploytime =
      InterstackResourceQueryDeploytime.queryDbStorageOfAllServicesExn(
        servicesOutputs,
      );

    let eventMappersOutputs = ref([||]);
    let queryEventCollector =
      InterstackResourceQueryRuntime.eventCollectorConnectorOfAllEventMappersExn(
        eventMappersOutputs->Interstack.mergeEventMappers,
      );

    let tasksOutputs = ref([||]);
    let queryBucketName =
      InterstackResourceQueryRuntime.bucketNameOfTaskExn(
        tasksOutputs->Interstack.mergeTasks,
      );

    let tasksOutputsWithEventMappers =
      taskMakers
      ->Belt.Array.map(taskMaker =>
          taskMaker(
            ~queryCommandTopic,
            ~queryQueryDb,
            ~queryEventCollector,
            ~queryBucketName,
            ~scheduler,
            ~opts=Some(opts),
          )
          ->Component.extractOutputs
        )
      ->Belt.Array.map(taskOutputs => {
          let eventMapperMaker =
            switch (taskOutputs##mappings, taskOutputs##policies) {
            | (None, _) => None
            | (
                Some((mappings: (module EventMapping.Mappings))),
                Some((policies: (module EventCollector.Policies))),
              ) =>
              module EventCollector =
                EventCollector.Make
                  // TODO: general EventCollector
                  ((val policies), EventCollectorAdapter);
              module EventMapper =
                EventMapper.Make((val mappings), EventCollector);
              Some(EventMapper.make);
            | (Some((mappings: (module EventMapping.Mappings))), None) =>
              module EventCollector =
                EventCollector.Make
                  // TODO: general EventCollector
                  (EventCollector.NoPolicies, EventCollectorAdapter);
              module EventMapper =
                EventMapper.Make((val mappings), EventCollector);
              Some(EventMapper.make);
            };
          (taskOutputs, eventMapperMaker);
        })
      ->Belt.Array.unzip;

    tasksOutputs := tasksOutputsWithEventMappers->fst;

    let taskEventMapperMakers =
      tasksOutputsWithEventMappers
      ->snd
      ->Belt.Array.keep(Belt.Option.isSome)
      ->Belt.Array.map(Belt.Option.getExn);

    eventMappersOutputs :=
      eventMapperMakers
      ->Belt.Array.map((eventMapperMaker: EventMapper.maker) =>
          eventMapperMaker(
            ~queryCommandTopic,
            ~queryEventTopic,
            ~memorySize=128,
            ~opts=Some(opts),
            (),
          )
        )
      ->Belt.Array.concat(
          taskEventMapperMakers->Belt.Array.map(
            (eventMapperMaker: EventMapper.maker) =>
            eventMapperMaker(
              ~queryCommandTopic,
              ~queryEventTopic,
              ~memorySize=1024,
              ~opts=Some(opts),
              (),
            )
          ),
        )
      ->Component.extractMultipleOutputs;

    let resolvers =
      servicesOutputs
      ->ResourceQueryDeploytime.allResolversMakers
      ->Belt.Array.map(resolverMaker => resolverMaker(queryQueryDbDeploytime))
      ->Belt.Array.concatMany;

    module Set = Belt.Set.String;

    let extensionPointAggregateNames =
      extensionPointsOutputs->Belt.Array.map(extensionPoint =>
        extensionPoint##aggregateNames->Set.fromArray
      );
    let serviceNameToEx = (exs, getServiceName) => {
      let dict = Js.Dict.empty();
      exs->Belt.Array.forEachU((. ex) =>
        ex
        ->getServiceName
        ->Belt.Array.forEachU((. aggregateName) =>
            switch (dict->Js.Dict.get(aggregateName)) {
            | Some(mappedExtensionPoints) =>
              Js.Dict.set(
                dict,
                aggregateName,
                mappedExtensionPoints->Belt.Array.concat([|ex|]),
              )
            | None => Js.Dict.set(dict, aggregateName, [|ex|])
            }
          )
      );
      dict;
    };

    let serviceNameToExtensionPointsMapping =
      serviceNameToEx(extensionPointsOutputs, extensionPoint =>
        extensionPoint##aggregateNames
      );
    let outgoingServiceNameToExtensionsMapping =
      serviceNameToEx(extensionsOutputs, extension =>
        extension##aggregateNames
      );
    let incomingServiceNameToExtensionsMapping =
      serviceNameToEx(allExtensionsOutputs, extension => [|extension##name|]);

    let extensionAggregateNames =
      extensionsOutputs->Belt.Array.map(extension =>
        extension##aggregateNames->Set.fromArray
      );

    let aggregateNames: array(string) =
      extensionPointAggregateNames
      ->Belt.Array.concat(extensionAggregateNames)
      ->Belt.Array.reduce(Set.empty, Set.union)
      ->Belt.Set.String.toArray
      ->Belt.Array.concat([|PluginExtensionPointSpec.name|]);

    let handleEvent = (event'Json, dict, getEventHandler) => {
      event'Json
      ->Message.serviceNameOfMsg
      ->Belt.Option.flatMap(serviceName => dict->Js.Dict.get(serviceName))
      ->Belt.Option.mapWithDefault(Js.Promise.resolve(), exs =>
          exs
          ->Belt.Array.map(ex => (getEventHandler(ex))(. event'Json))
          ->Js.Promise.all
          ->Js.Promise.then_(_ => Js.Promise.resolve(), _)
        );
    };

    let getExtensionPointOutgoingEventHandler = extensionPoint =>
      extensionPoint##outgoingEventHandler;
    let getExtensionOutgoingEventHandler = extension =>
      extension##outgoingEventHandler;
    let getExtensionIncomingEventHandler = extension =>
      extension##incomingEventHandler;

    let detectUnhandledEvent = event'Json =>
      event'Json
      ->Message.serviceNameOfMsg
      ->Belt.Option.flatMap(serviceName =>
          switch (
            serviceNameToExtensionPointsMapping->Js.Dict.get(serviceName),
            incomingServiceNameToExtensionsMapping->Js.Dict.get(serviceName),
            outgoingServiceNameToExtensionsMapping->Js.Dict.get(serviceName),
          ) {
          | (None, None, None) => None
          | _ => Some()
          }
        )
      ->(
          fun
          | None => Js.log2("Unhandled Event:", event'Json)
          | _ => ()
        );

    let eventHandler =
      (. event'Json) => {
        detectUnhandledEvent(event'Json);
        (
          handleEvent(
            event'Json,
            serviceNameToExtensionPointsMapping,
            getExtensionPointOutgoingEventHandler,
          ),
          handleEvent(
            event'Json,
            outgoingServiceNameToExtensionsMapping,
            getExtensionOutgoingEventHandler,
          ),
          handleEvent(
            event'Json,
            incomingServiceNameToExtensionsMapping,
            getExtensionIncomingEventHandler,
          ),
        )
        ->Js.Promise.all3
        ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
      };

    module EventCollector =
      EventCollector.Make(EventCollector.NoPolicies, EventCollectorAdapter);

    let eventCollector =
      EventCollector.make(
        ~name=name ++ componentType->ComponentType.toString,
        ~aggregateNames,
        ~eventHandler,
        ~queryEventTopic,
        ~opts=Some(opts),
        (),
      );
    let eventCollectorOutputs = eventCollector->Component.extractOutputs;
    eventCollectorId :=  eventCollectorOutputs##connector##id;

    let heartbeat =
      Heartbeat.make(
        ~id,
        ~name=name ++ componentType->ComponentType.toString,
        ~timeout,
        ~commandTopicId=corePluginCommandTopicId,
        ~opts,
        (),
      );

    makeOutputs(
      ~eventCollector=eventCollectorOutputs,
      ~extensionPoints=extensionPointsOutputs->toDict,
      ~extensions=extensionsOutputs->toDict,
      ~services=servicesOutputs->toDict,
      ~tasks=(tasksOutputs^)->toDict,
      ~eventMappers=(eventMappersOutputs^)->toDict,
      ~resolvers,
      ~heartbeat=heartbeat->Component.extractOutputs,
    )
    ->setOutputs(self, _);
  };

  let make: maker =
    (
      ~name,
      ~version,
      ~timeout,
      ~extensionPointMakers,
      ~extensionMakers,
      ~serviceMakers,
      ~taskMakers,
      ~eventMapperMakers,
      ~scheduler,
      ~opts=?,
      _unit,
    ) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct=
          construct(
            ~version,
            ~timeout,
            ~extensionPointMakers,
            ~extensionMakers,
            ~serviceMakers,
            ~taskMakers,
            ~eventMapperMakers,
            ~scheduler,
          ),
        ~opts,
      );
};
