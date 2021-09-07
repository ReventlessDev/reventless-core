// TODO: refactor to smaller code parts for a better overview
open ReventlessSpec.Adapter;

let componentType = ComponentType.Plugin;

type outputFields = {
  .
  "id": string,
  "version": string,
  "heartbeatInterval": int,
  "eventCollector": EventCollector.outputs,
  "extensionPoints": Js.Dict.t(ExtensionPoint.outputs),
  "extensions": Js.Dict.t(Extension.outputs),
  "services": Js.Dict.t(Service.outputs),
  "tasks": Js.Dict.t(Task.outputs),
  "eventMappers": Js.Dict.t(EventMapper.outputs),
  "resolvers": array(resource),
  "heartbeat": Heartbeat.outputs,
  "serviceNameToExtensionPointsMapping":
    Js.Dict.t(array(ExtensionPoint.outputs)),
  "outgoingServiceNameToExtensionsMapping":
    Js.Dict.t(array(Extension.outputs)),
  "incomingServiceNameToExtensionsMapping":
    Js.Dict.t(array(Extension.outputs)),
  "resources": resources,
};

type outputs = {. "outputs": Pulumi.Output.t(outputFields)};

type plugin; // TODO: rename to t - after refactoring

type maker =
  (
    ~name: string,
    ~version: string,
    ~heartbeatInterval: int,
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

let makeId = (name, version) => {j|$name@$version|j};

module Make =
       (
         EventCollectorAdapter: EventCollector.Adapter.Connector,
         QueryEngineAdapter: QueryDb.Adapter.QueryEngineAdapter,
       )
       : T => {
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
  external makeOutputFields:
    (
      ~id: string,
      ~version: string,
      ~heartbeatInterval: int,
      ~eventCollector: EventCollector.outputs,
      ~extensionPoints: Js.Dict.t(ExtensionPoint.outputs),
      ~extensions: Js.Dict.t(Extension.outputs),
      ~services: Js.Dict.t(Service.outputs),
      ~tasks: Js.Dict.t(Task.outputs),
      ~eventMappers: Js.Dict.t(EventMapper.outputs),
      ~resolvers: array(resource),
      ~heartbeat: Heartbeat.outputs,
      ~serviceNameToExtensionPointsMapping: Js.Dict.t(
                                              array(ExtensionPoint.outputs),
                                            ),
      ~outgoingServiceNameToExtensionsMapping: Js.Dict.t(
                                                 array(Extension.outputs),
                                               ),
      ~incomingServiceNameToExtensionsMapping: Js.Dict.t(
                                                 array(Extension.outputs),
                                               ),
      ~resources: resources
    ) =>
    outputFields =
    "";

  [@bs.obj]
  external makeOutputs: (~outputs: Pulumi.Output.t(outputFields)) => outputs =
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
        ~heartbeatInterval: int,
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

    let id = makeId(name, version);

    let resources: resources = Js.Dict.empty();

    let services =
      serviceMakers->Belt.Array.map(serviceMaker =>
        serviceMaker(~opts, ~resources, ())
      );
    let servicesOutputs = services->Component.extractMultipleOutputs;

    (
      switch (Interstack.coreStackOutput) {
      | Some(coreStackOutput) => coreStackOutput
      | None =>
        Js.Exn.raiseError(
          "No Core Stack configured! (Please set 'core:stack: user/project/stack' in you Pulumi.*.config!",
        )
      }
    )
    ->Pulumi.Output.apply(coreStackOutput => {
        open Pulumi.StackReference.Infix;
        let corePluginExtensionPoint =
          coreStackOutput##extensionPoints->Belt.Option.getExn
          -# ReventlessSpec.PluginExtensionPointSpec.name;

        let corePluginCommandTopic =
          corePluginExtensionPoint##commandTopic##connector
          ->Obj.magic // StackReference outputs are not wrapped in Pulumi.Outputs !
          ->Adapter.toResource;
        let corePluginCommandTopicId = corePluginCommandTopic##id;

        resources->Util.ExtensionPoint.setCommandTopicConnectorResource(
          corePluginCommandTopic,
          ReventlessSpec.PluginExtensionPointSpec.name,
        );
        resources->Util.ExtensionPoint.setEventTopicPublisherResource(
          corePluginExtensionPoint##eventTopic##publisher
          ->Obj.magic // StackReference outputs are not wrapped in Pulumi.Outputs !
          ->Adapter.toResource,
          ReventlessSpec.PluginExtensionPointSpec.name,
        );

        let queryEngine = QueryEngineAdapter.make(resources);

        let extensionPoints =
          extensionPointMakers->Belt.Array.map(extensionPointMaker =>
            extensionPointMaker(
              ~scheduler,
              ~queryEngine,
              ~opts=Some(opts),
              ~resources,
              (),
            )
          );
        let extensionPointsOutputs =
          extensionPoints->Component.extractMultipleOutputs;

        let extensions =
          extensionMakers->Belt.Array.map(extensionMaker =>
            extensionMaker(
              ~pluginExtensionPointCommandTopicId=corePluginCommandTopicId,
              ~queryEngine,
              ~opts=Some(opts),
              ~resources,
              (),
            )
          );
        let extensionsOutputs = extensions->Component.extractMultipleOutputs;

        let (eventCollectorUrn, setEventCollectorUrn) =
          Util.Pulumi.Output.Async.make();
        open AwsSdk;

        let addStatement = (policy: IAM.Policy.t, sid, queueArn, topicArn) => {
          let newStatements =
            policy##_Statement
            ->Belt.Array.keep(statement => statement##_Sid != sid)
            ->Belt.Array.concat([|
                IAM.Policy.Statement.make(
                  ~_Sid=sid,
                  ~_Effect="Allow",
                  ~_Principal="*",
                  ~_Action="sqs:SendMessage",
                  ~_Resource=queueArn,
                  ~_Condition=IAM.Policy.Statement.Condition.make(topicArn),
                  (),
                ),
              |]);
          Js.log({j|addStatement: adding 1 statement with Sid $sid|j});
          IAM.Policy.make(
            ~_Version=policy##_Version,
            ~_Id=policy##_Id,
            ~_Statement=newStatements,
          );
        };

        let removeStatement = (policy, sid) => {
          let statements = policy##_Statement;
          let newStatements =
            statements->Belt.Array.keep(statement => statement##_Sid != sid);
          let removedStatements =
            statements->Belt.Array.length - newStatements->Belt.Array.length;
          Js.log(
            {j|removeStatement: removing $removedStatements statement(s) with Sid $sid|j},
          );
          IAM.Policy.make(
            ~_Version=policy##_Version,
            ~_Id=policy##_Id,
            ~_Statement=newStatements,
          );
        };

        let _addPermission = (sid, eventCollector, eventTopic) =>
          SQS.getQueuePolicy(eventCollector)
          ->Js.Promise.then_(
              policy =>
                eventCollector->SQS.setQueuePolicy(
                  policy->addStatement(sid, eventCollector, eventTopic),
                ),
              _,
            );

        let _removePermission = (sid, eventCollector) =>
          SQS.getQueuePolicy(eventCollector)
          ->Js.Promise.then_(
              policy =>
                eventCollector->SQS.setQueuePolicy(
                  policy->removeStatement(sid),
                ),
              _,
            );

        let subscribe =
            (action, extensionPointName, eventTopic, pluginId, eventCollector) => {
          let eventTopicName = eventTopic->AWS.arn2Name;
          let eventCollectorName = eventCollector->AWS.arn2Name;
          let _sid = (extensionPointName ++ "-" ++ pluginId)->AWS.validateName;
          SNS.subscribeQueueToTopic(eventCollector, eventTopic)
          ->Js.Promise.then_(
              _ =>
                Js.log(
                  {j|$action: $extensionPointName->$pluginId ($eventTopicName->$eventCollectorName)|j},
                )
                ->Js.Promise.resolve,
              _,
            )
          ->Js.Promise.catch(
              err =>
                Js.log2(
                  {j|Could not $action: $extensionPointName->$pluginId ($eventTopicName->$eventCollectorName):|j},
                  err,
                )
                ->Js.Promise.resolve,
              _,
            );
        };

        let unsubscribe =
            (action, extensionPointName, eventTopic, pluginId, eventCollector) => {
          let eventTopicName = eventTopic->AWS.arn2Name;
          let eventCollectorName = eventCollector->AWS.arn2Name;
          let _sid = (extensionPointName ++ "-" ++ pluginId)->AWS.validateName;

          SNS.unsubscribeQueueFromTopic(eventCollector, eventTopic)
          ->Js.Promise.then_(
              _ =>
                Js.log(
                  {j|$action: $extensionPointName->$pluginId ($eventTopicName->$eventCollectorName)|j},
                )
                ->Js.Promise.resolve,
              _,
            )
          ->Js.Promise.catch(
              err =>
                Js.log2(
                  {j|Could not $action: $extensionPointName->$pluginId ($eventTopicName->$eventCollectorName):|j},
                  err,
                )
                ->Js.Promise.resolve,
              _,
            );
        };

        let callHandler =
          fun
          | ReventlessSpec.PluginExtensionPointSpec.DoConnectPlugin({
              id: pluginId,
              extensionPoints: pluginExtensionPoints,
              extensions: pluginExtensions,
              eventCollector: pluginEventCollector,
            }) => {
              /* Current Plugin received `PluginConnected`:
               *  this means: current plugin was already deployed before and received plugin just has been deployed
               * - connectToExtensionPoints: if the newly deployed (received) plugin contains extensionpoints
               *    the current plugin relies on: connect current plugin to received plugin extension point's eventTopic
               * - if the newly deployed (received) plugin contains extensions the current plugin holds an extensionpoint for:
               *    connect received extensions to current plugin's extension point
               */
              let connectToExtensionPoints =
                pluginExtensionPoints
                ->Belt.Array.keepMap(
                    ({name: extensionPointName, eventTopic}) =>
                    extensionsOutputs
                    ->Belt.Array.keep(extension =>
                        extension##extensionPointName == extensionPointName
                      )
                    ->Belt.Array.length
                    > 0
                      ? Some(
                          subscribe(
                            "connectToExtensionPoints",
                            extensionPointName,
                            eventTopic,
                            id,
                            eventCollectorUrn->Pulumi.Output.get,
                          ),
                        )
                      : None
                  )
                ->Js.Promise.all
                ->Js.Promise.then_(_ => Js.Promise.resolve(), _);

              let connectToExtensions =
                extensionPointsOutputs
                ->Belt.Array.keepMap(extensionPoint =>
                    pluginExtensions
                    ->Belt.Array.keep(({extensionPointName}) =>
                        extensionPoint##name == extensionPointName
                      )
                    ->Belt.Array.length
                    > 0
                      ? Some(
                          subscribe(
                            "connectToExtensions",
                            extensionPoint##name,
                            extensionPoint##eventTopic##publisher##id
                            ->Pulumi.Output.get,
                            pluginId,
                            pluginEventCollector,
                          ),
                        )
                      : None
                  )
                ->Js.Promise.all
                ->Js.Promise.then_(_ => Js.Promise.resolve(), _);

              // await connections of extensionpoints & extensions
              Js.Promise.all2((connectToExtensionPoints, connectToExtensions))
              ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
            }
          | DoDisconnectPlugin({
              id: pluginId,
              extensionPoints: pluginExtensionPoints,
              extensions: pluginExtensions,
              eventCollector: pluginEventCollector,
            }) => {
              let disconnectFromExtensionPoints =
                pluginExtensionPoints
                ->Belt.Array.keepMap(
                    ({name: extensionPointName, eventTopic}) =>
                    extensionsOutputs
                    ->Belt.Array.keep(extension =>
                        extension##extensionPointName == extensionPointName
                      )
                    ->Belt.Array.length
                    > 0
                      ? Some(
                          unsubscribe(
                            "disconnectFromExtensionPoints",
                            extensionPointName,
                            eventTopic,
                            id,
                            eventCollectorUrn->Pulumi.Output.get,
                          ),
                        )
                      : None
                  )
                ->Js.Promise.all
                ->Js.Promise.then_(_ => Js.Promise.resolve(), _);

              let disconnectFromExtensions =
                extensionPointsOutputs
                ->Belt.Array.keepMap(extensionPoint =>
                    pluginExtensions
                    ->Belt.Array.keep(({extensionPointName}) =>
                        extensionPoint##name == extensionPointName
                      )
                    ->Belt.Array.length
                    > 0
                      ? Some(
                          unsubscribe(
                            "disconnectFromExtensions",
                            extensionPoint##name,
                            extensionPoint##eventTopic##publisher##id
                            ->Pulumi.Output.get,
                            pluginId,
                            pluginEventCollector,
                          ),
                        )
                      : None
                  )
                ->Js.Promise.all
                ->Js.Promise.then_(_ => Js.Promise.resolve(), _);

              Js.Promise.all2((
                disconnectFromExtensionPoints,
                disconnectFromExtensions,
              ))
              ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
            }
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
          (extensionPointsConfig, eventCollectorUrn)
          ->Pulumi.Output.all2
          ->Pulumi.Output.apply(((extensionPointsConfig, eventCollectorUrn)) =>
              {
                PluginSpec.id,
                name,
                version,
                extensionPoints: extensionPointsConfig,
                extensions: extensionsConfig,
                eventCollector: eventCollectorUrn,
              }
            );

        module ConnectPluginExtensionMapping =
          ExtensionMapping.Make(
            ReventlessSpec.PluginExtensionPointSpec,
            {
              module Aggregate = ReventlessSpec.ExtensionMapping.NoAggregate;

              let mapIncomingEvent:
                ReventlessSpec.ExtensionMapping.mapIncomingEvent(
                  ReventlessSpec.PluginExtensionPointSpec.event,
                  Aggregate.command,
                  ReventlessSpec.PluginExtensionPointSpec.command,
                  ReventlessSpec.PluginExtensionPointSpec.callCommand,
                ) =
                (pluginId, event, _meta, _pluginDef, _queryEngine) =>
                  switch (event) {
                  | ReventlessSpec.PluginExtensionPointSpec.UnknownPluginDetected
                      when pluginId == id => [|
                      PublishExtensionPointCommand(
                        id,
                        ReventlessSpec.PluginExtensionPointSpec.ConnectPlugin(
                          pluginDefinition->Pulumi.Output.get,
                        ),
                      ),
                    |]
                  | PluginConnected(pluginDef)
                  | PluginReconnected(pluginDef) when pluginId != id => [|
                      Call(callHandler, DoConnectPlugin(pluginDef)),
                    |]
                  | PluginDeactivated(pluginDef) when pluginId != id => [|
                      Call(callHandler, DoDisconnectPlugin(pluginDef)),
                    |]
                  // don't disconnect because a newer version might be already connected
                  // if the old version gets destroyed, then the subscription is also destroyed
                  | PluginDisconnected(_) => [||]
                  | _ => [||]
                  };

              let mapOutgoingEvent = (_id, _event, _meta, _pluginDef) => [||];
            },
          );

        module ConnectPluginExtension =
          Extension.Make(ReventlessSpec.PluginExtensionPointSpec);
        let connectPluginExtensionMaker =
          ConnectPluginExtension.make(
            "Connect",
            [|(module ConnectPluginExtensionMapping)|],
          );
        let connectPluginExtension =
          connectPluginExtensionMaker(
            ~pluginExtensionPointCommandTopicId=corePluginCommandTopicId,
            ~queryEngine,
            ~opts=Some(opts),
            ~resources,
            (),
          );

        let tasksOutputs = ref([||]);
        let queryBucketName =
          InterstackResourceQueryRuntime.bucketNameOfTaskExn(
            tasksOutputs->Interstack.mergeTasks,
          );

        tasksOutputs :=
          taskMakers->Belt.Array.map(taskMaker =>
            taskMaker(
              ~queryBucketName,
              ~scheduler,
              ~queryEngine,
              ~opts=Some(opts),
              ~resources,
            )
            ->Component.extractOutputs
          );

        let eventMappersOutputs =
          eventMapperMakers
          ->Belt.Array.map((eventMapperMaker: EventMapper.maker) =>
              eventMapperMaker(
                ~queryEngine,
                ~memorySize=128,
                ~opts=Some(opts),
                ~resources,
                (),
              )
            )
          ->Component.extractMultipleOutputs;

        let resolvers =
          servicesOutputs
          ->ResourceQueryDeploytime.allResolversMakers
          ->Belt.Array.map(resolverMaker => resolverMaker(resources))
          ->Belt.Array.concatMany;

        module Set = Belt.Set.String;

        let collectAggregateNames = exs =>
          exs->Belt.Array.map(ex =>
            ex##aggregateNames
            ->Set.fromArray
            ->Set.remove(ReventlessSpec.ExtensionMapping.NoAggregate.name)
          );

        let extensionPointAggregateNames =
          extensionPointsOutputs->collectAggregateNames;

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

        let incomingServiceNameToPluginConnectExtensionsMapping =
          serviceNameToEx(
            [|connectPluginExtension->Component.extractOutputs|], extension =>
            [|extension##extensionPointName|]
          );
        let serviceNameToExtensionPointsMapping =
          serviceNameToEx(extensionPointsOutputs, extensionPoint =>
            extensionPoint##aggregateNames
          );
        let outgoingServiceNameToExtensionsMapping =
          serviceNameToEx(extensionsOutputs, extension =>
            extension##aggregateNames
          );
        let incomingServiceNameToExtensionsMapping =
          serviceNameToEx(extensionsOutputs, extension =>
            [|extension##extensionPointName|]
          );

        let extensionAggregateNames = extensionsOutputs->collectAggregateNames;

        let handleEvent = (event'Json, dict, getEventHandler) => {
          event'Json
          ->Message.serviceNameOfMsg
          ->Belt.Option.flatMap(serviceName => dict->Js.Dict.get(serviceName))
          ->Belt.Option.mapWithDefault(Js.Promise.resolve(), exs =>
              exs
              ->Belt.Array.map(ex =>
                  ex->getEventHandler(.
                    event'Json,
                    pluginDefinition->Pulumi.Output.get,
                  )
                )
              ->Js.Promise.all
              ->Js.Promise.then_(_ => Js.Promise.resolve(), _)
            );
        };

        let detectUnhandledEvent = event'Json =>
          event'Json
          ->Message.serviceNameOfMsg
          ->Belt.Option.flatMap(serviceName =>
              switch (
                serviceNameToExtensionPointsMapping->Js.Dict.get(serviceName),
                incomingServiceNameToExtensionsMapping->Js.Dict.get(
                  serviceName,
                ),
                outgoingServiceNameToExtensionsMapping->Js.Dict.get(
                  serviceName,
                ),
              ) {
              | (None, None, None) => None
              | _ => Some()
              }
            )
          ->(
              fun
              | None => Js.log("No mapping matches service name")
              | _ => ()
            );

        let _sideEffectHandlers =
          (tasksOutputs^)
          ->Belt.Array.keepMap(taskOutput =>
              taskOutput##sideEffectHandler
              ->Belt.Option.map(sideEffectHandler =>
                  sideEffectHandler##eventsHandler
                )
            );

        let eventsHandler =
          (. events'Json) => {
            let count = events'Json->Belt.Array.size;
            events'Json
            ->Belt.Array.mapWithIndex((idx, event'Json) => {
                let idx = idx + 1;
                event'Json->Message.logEvent'Json(
                  {j|Plugin $id eventsHandler: incoming event $idx/$count:|j},
                );
                detectUnhandledEvent(event'Json);
                handleEvent(
                  event'Json,
                  incomingServiceNameToPluginConnectExtensionsMapping,
                  extension =>
                  extension##incomingEventHandler
                )
                ->Js.Promise.then_(
                    _ =>
                      [|
                        event'Json->handleEvent(
                          serviceNameToExtensionPointsMapping, extensionPoint =>
                          extensionPoint##outgoingEventHandler
                        ),
                        event'Json->handleEvent(
                          outgoingServiceNameToExtensionsMapping, extension =>
                          extension##outgoingEventHandler
                        ),
                        event'Json->handleEvent(
                          incomingServiceNameToExtensionsMapping, extension =>
                          extension##incomingEventHandler
                        ),
                      |]
                      ->Js.Promise.all
                      ->Js.Promise.then_(_ => Js.Promise.resolve(), _),
                    _,
                  );
              })
            ->Js.Promise.all
            ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
          };

        module EventCollector =
          EventCollector.Make(
            EventCollector.DefaultPolicies,
            EventCollectorAdapter,
          );

        let eventCollector =
          EventCollector.make(
            ~name=name->ComponentType.name(componentType),
            ~aggregateNames=
              extensionPointAggregateNames
              ->Belt.Array.concat(extensionAggregateNames)
              ->Belt.Array.reduce(Set.empty, Set.union)
              ->Belt.Set.String.toArray,
            ~extensionPointNames=[|
              ReventlessSpec.PluginExtensionPointSpec.name,
            |],
            ~eventsHandler,
            ~opts=Some(opts),
            ~resources,
            (),
          );
        let eventCollectorOutputs = eventCollector->Component.extractOutputs;
        setEventCollectorUrn(.
          eventCollectorOutputs##connector->Belt.Option.getExn##urn,
        );

        let heartbeat =
          Heartbeat.make(
            ~id,
            ~name=name ++ componentType->ComponentType.toName,
            ~timeout=heartbeatInterval,
            ~commandTopicId=corePluginCommandTopicId,
            ~opts,
            (),
          );

        makeOutputFields(
          ~id,
          ~version,
          ~heartbeatInterval,
          ~eventCollector=eventCollectorOutputs,
          ~extensionPoints=extensionPointsOutputs->toDict,
          ~extensions=extensionsOutputs->toDict,
          ~services=servicesOutputs->toDict,
          ~tasks=(tasksOutputs^)->toDict,
          ~eventMappers=eventMappersOutputs->toDict,
          ~resolvers,
          ~heartbeat=heartbeat->Component.extractOutputs,
          ~serviceNameToExtensionPointsMapping,
          ~outgoingServiceNameToExtensionsMapping,
          ~incomingServiceNameToExtensionsMapping,
          ~resources,
        );
      })
    ->makeOutputs(~outputs=_)
    ->setOutputs(self, _);
  };

  let make: maker =
    (
      ~name,
      ~version,
      ~heartbeatInterval,
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
            ~heartbeatInterval,
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
