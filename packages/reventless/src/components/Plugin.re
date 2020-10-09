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
  "serviceNameToExtensionPointsMapping":
    Js.Dict.t(array(ExtensionPoint.outputs)),
  "outgoingServiceNameToExtensionsMapping":
    Js.Dict.t(array(Extension.outputs)),
  "incomingServiceNameToExtensionsMapping":
    Js.Dict.t(array(Extension.outputs)),
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
      ~heartbeat: Heartbeat.outputs,
      ~serviceNameToExtensionPointsMapping: Js.Dict.t(
                                              array(ExtensionPoint.outputs),
                                            ),
      ~outgoingServiceNameToExtensionsMapping: Js.Dict.t(
                                                 array(Extension.outputs),
                                               ),
      ~incomingServiceNameToExtensionsMapping: Js.Dict.t(
                                                 array(Extension.outputs),
                                               )
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

    let coreStackOutput =
      switch (Interstack.coreStackOutput) {
      | Some(coreStackOutput) => coreStackOutput
      | None =>
        Js.Exn.raiseError(
          "No Core Stack configured! (Please set 'core:stack: user/project/stack' in you Pulumi.*.config!",
        )
      };
    open Pulumi.StackReference.Infix;

    let corePluginCommandTopicId =
      coreStackOutput->Pulumi.Output.flatMap(output =>
        (
          output##extensionPoints->Belt.Option.getExn
          -# PluginExtensionPointSpec.name
        )##commandTopic##connector##id
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
        coreStackOutput->Pulumi.Output.apply(output =>
          (
            output##extensionPoints->Belt.Option.getExn
            -# PluginExtensionPointSpec.name
          )##eventTopic##publisher
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

    let eventCollectorUrn: ref(Pulumi.Output.t(string)) =
      ref("NOT-SET"->Pulumi.Output.make);

    let callHandler =
      fun
      | PluginExtensionPointSpec.ConnectPlugin(pluginSpec) => {
          /* Current Plugin recieved `PluginConnected`:
           *  this means: current plugin was already deployed before and recieved plugin just has been deployed
           * - connectToExtensionPointsOfTheConnectedPlugin: if the newly deployed (recieved) plugin contains extensionpoints the current plugin relies on: connect current plugin to recieved plugin extension point's eventTopic
           * - if the newly deployed (recieved) plugin contains extensions the current plugin holds an extensionpoint for: connect recieved extensions to current plugin's extension point
           */
          let connectToExtensionPointsOfConnectedPlugin =
            // TODO: validate if this handling is correct - see connectToExtensionsOfTheConnectedPlugin: if a plugin has several extension for one extPt. it only needs to connect once
            pluginSpec.extensionPoints
            ->Belt.Array.map(extensionPoint =>
                extensionsOutputs->Belt.Array.keepMap(extension =>
                  if (extension##extensionPointName == extensionPoint.name) {
                    let eventCollectorUrn =
                      (eventCollectorUrn^)->Pulumi.Output.get;
                    AwsSdk.SNS.(
                      snsClient()
                      ->subscribe(
                          ~params=
                            SubscribeRequest.make(
                              ~_TopicArn=extensionPoint.eventTopic,
                              ~_Protocol=`sqs,
                              ~_Endpoint=eventCollectorUrn,
                              /* TODO: add dlq in params.redrivePolicy */
                              (),
                            ),
                        )
                    )
                    ->AwsSdk.Request.promise
                    ->Js.Promise.then_(_ => Js.Promise.resolve(), _)
                    ->Js.Promise.catch(
                        err =>
                          Js.log2(
                            "Could not connect Plugins"
                            ++ (pluginSpec.name ++ ":" ++ extensionPoint.name)
                            ++ " (Ext.P.) ->"
                            ++ name
                            ++ ":"
                            ++
                            extension##name
                            ++ ": ",
                            err,
                          )
                          ->Js.Promise.resolve,
                        _,
                      )
                    ->Some;
                  } else {
                    None;
                  }
                )
              )
            ->Belt.Array.concatMany
            ->Js.Promise.all
            ->Js.Promise.then_(_ => Js.Promise.resolve(), _);

          let connectToExtensionsOfConnectedPlugin = {
            /* pluginSpec.extensions could hold several extensions
             * for the same extensionpoint but we only connect once
             */
            let connections:
              array(
                (
                  string /*EventTopic*/,
                  (
                    string /*extensionPointName*/,
                    PluginSpec.plugin /*PluginSpec*/,
                  ),
                ),
              ) = {
              let conns = Js.Dict.empty();
              extensionPointsOutputs->Belt.Array.forEach(extensionPoint =>
                if (Util.Array.containsByPredicate(
                      pluginSpec.extensions, extension =>
                      extensionPoint##name == extension.extensionPointName
                    )) {
                  Js.Dict.set(
                    conns,
                    extensionPoint##eventTopic##publisher##id
                    ->Pulumi.Output.get,
                    (extensionPoint##name, pluginSpec),
                  );
                }
              );
              conns->Js.Dict.entries;
            };
            connections
            ->Belt.Array.map(
                ((eventTopic, (extensionPointName, pluginSpec))) =>
                AwsSdk.SNS.(
                  snsClient()
                  ->subscribe(
                      ~params=
                        SubscribeRequest.make(
                          ~_TopicArn=eventTopic,
                          ~_Protocol=`sqs,
                          ~_Endpoint=pluginSpec.eventCollector,
                          /* TODO: add dlq in params.redrivePolicy */
                          (),
                        ),
                    )
                )
                ->AwsSdk.Request.promise
                ->Js.Promise.then_(_ => Js.Promise.resolve(), _)
                ->Js.Promise.catch(
                    err =>
                      Js.log2(
                        "Could not connect extensionpoint "
                        ++ extensionPointName
                        ++ " ["
                        ++ name
                        ++ "] to "
                        ++ pluginSpec.name
                        ++ ": ",
                        err,
                      )
                      ->Js.Promise.resolve,
                    _,
                  )
              )
            ->Js.Promise.all
            ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
          };

          // await connections of extensionpoints & extensions
          Js.Promise.all2((
            connectToExtensionPointsOfConnectedPlugin,
            connectToExtensionsOfConnectedPlugin,
          ))
          ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
        }
      // for every ExtensionPoint of the connected Plugin which has a related Extension in this Plugin -> connect
      // TODO: Try to Unsubscribe from Event-Topic, if extensionpoint's plugin disconnected
      | _ => Js.Promise.resolve();
    let extensionPointsConfig =
      extensionPointsOutputs
      ->Belt.Array.map(extensionPoint =>
          (
            extensionPoint##commandTopic##connector##id,
            extensionPoint##eventTopic##publisher##id,
          )
          ->Pulumi.Output.all2
          ->Pulumi.Output.apply(
              ((commandTopicConnectorId, eventTopicPublisherId)) =>
              {
                PluginSpec.name: extensionPoint##name,
                commandTopic: commandTopicConnectorId,
                eventTopic: eventTopicPublisherId,
              }
            )
        )
      ->Pulumi.Output.all;
    let extensionsConfig = {
      extensionsOutputs->Belt.Array.map(extension =>
        {
          PluginSpec.name: extension##name,
          extensionPointName: extension##extensionPointName,
        }
      );
    };
    let pluginDefinition =
      (extensionPointsConfig, eventCollectorUrn^)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((extensionPointsConfig, eventCollectorUrn)) =>
          {
            PluginSpec.name,
            version,
            extensionPoints: extensionPointsConfig,
            extensions: extensionsConfig,
            eventCollector: eventCollectorUrn,
          }
        );

    module ConnectPluginExtensionMapping =
      ExtensionMapping.Make(
        PluginExtensionPointSpec,
        {
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
                    PluginExtensionPointSpec.ConnectPlugin(
                      pluginDefinition->Pulumi.Output.get,
                    ),
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

    module ConnectPluginExtension = Extension.Make(PluginExtensionPointSpec);
    let dconnectPluginExtensionMaker =
      ConnectPluginExtension.make(
        "Connect",
        [|(module ConnectPluginExtensionMapping)|],
      );
    let connectPluginExtension =
      dconnectPluginExtensionMaker(
        ~queryCommandTopic,
        ~queryExtensionPointCommandTopicId,
        ~opts=Some(opts),
        (),
      );

    let allExtensionsOutputs =
      extensionsOutputs->Belt.Array.concat([|
        connectPluginExtension->Component.extractOutputs,
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
    let serviceNameToEx = (exs, getServiceNames) => {
      let dict = Js.Dict.empty();
      exs->Belt.Array.forEachU((. ex) =>
        ex
        ->getServiceNames
        ->Belt.Array.forEachU((. serviceName) =>
            switch (dict->Js.Dict.get(serviceName)) {
            | Some(mappedExtensionPoints) =>
              Js.Dict.set(
                dict,
                serviceName,
                mappedExtensionPoints->Belt.Array.concat([|ex|]),
              )
            | None => Js.Dict.set(dict, serviceName, [|ex|])
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
      serviceNameToEx(allExtensionsOutputs, extension =>
        [|extension##extensionPointName|]
      );

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
          | None => Js.log("Event Unhandled")
          | _ => ()
        );

    let eventHandler =
      (. event'Json) => {
        Js.log2(
          "Plugin eventHandler: incoming event:",
          event'Json->Js.Json.stringify,
        );
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
    eventCollectorUrn :=  eventCollectorOutputs##connector##urn;

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
      ~serviceNameToExtensionPointsMapping,
      ~outgoingServiceNameToExtensionsMapping,
      ~incomingServiceNameToExtensionsMapping,
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
