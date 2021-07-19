// TODO: refactor to smaller code parts for a better overview
open ReventlessSpec.Adapter;

let componentType = ComponentType.Plugin;

type outputs = {
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
};

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
         EventCollectorAdapter: EventCollector.Connector,
         QueryEngineAdapter: QueryDb.QueryEngineAdapter,
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
  external makeOutputs:
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
          -# ReventlessSpec.PluginExtensionPointSpec.name
        )##commandTopic##connector##id
      );

    let queryEventTopic = name =>
      if (name == ReventlessSpec.PluginExtensionPointSpec.name) {
        coreStackOutput->Pulumi.Output.apply(output =>
          (
            output##extensionPoints->Belt.Option.getExn
            -# ReventlessSpec.PluginExtensionPointSpec.name
          )##eventTopic##publisher
        );
      } else {
        InterstackResourceQueryDeploytime.eventTopicPublisherOfAllServicesExn(
          servicesOutputs,
          name,
        );
      };

    let queryQueryDb =
      InterstackResourceQueryRuntime.queryDbStorageOfAllServicesExn(
        servicesOutputs->Interstack.mergeServices,
      );

    let queryQueryDbDeploytime =
      InterstackResourceQueryDeploytime.queryDbStorageOfAllServicesExn(
        servicesOutputs,
      );

    let queryEngine = QueryEngineAdapter.make(queryQueryDb);

    let extensionPoints =
      extensionPointMakers->Belt.Array.map(extensionPointMaker =>
        extensionPointMaker(
          ~queryCommandTopic,
          ~scheduler,
          ~queryEngine,
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
          ~pluginExtensionPointCommandTopicId=corePluginCommandTopicId,
          ~queryEngine,
          ~opts=Some(opts),
          (),
        )
      );
    let extensionsOutputs = extensions->Component.extractMultipleOutputs;

    let (eventCollectorUrn, setEventCollectorUrn) =
      Util.Pulumi.Output.Async.make();
    open AwsSdk;

    let subscribeQueueToTopic = (queueArn, topicArn) =>
      SNS.(
        snsClient()
        ->subscribe(
            ~params=
              SubscribeRequest.make(
                ~_TopicArn=topicArn,
                ~_Protocol=`sqs,
                ~_Endpoint=queueArn,
                ~_Attributes=
                  SubscribeRequest.Attributes.make(
                    ~_RawMessageDelivery="true",
                    /* TODO: add dlq in RedrivePolicy */
                    (),
                  ),
                (),
              ),
          )
      )
      ->Request.promise
      ->Js.Promise.then_(
          subscriptionResponse =>
            Js.log2("subscribed:", subscriptionResponse##_SubscriptionArn)
            ->Js.Promise.resolve,
          _,
        );

    let unsubscribeQueueFromTopic = (queueArn, topicArn) => {
      SNS.(
        snsClient()
        ->listSubscriptionsByTopic(
            ~params=
              ListSubscriptionsByTopicRequest.make(~_TopicArn=topicArn, ()),
          ) // TODO: handle paging of subscriptions
        ->Request.promise
        ->Js.Promise.then_(
            response =>
              response##_Subscriptions
              ->Belt.Array.getBy(subscription =>
                  subscription##_Endpoint == queueArn
                )
              ->Belt.Option.map(subscription =>
                  snsClient()
                  ->unsubscribe(
                      ~params=
                        UnsubscribeRequest.make(
                          ~_SubscriptionArn=subscription##_SubscriptionArn,
                        ),
                    )
                  ->Request.promise
                  ->Js.Promise.then_(
                      _ =>
                        Js.log2(
                          "unsubscribed:",
                          subscription##_SubscriptionArn,
                        )
                        ->Js.Promise.resolve,
                      _,
                    )
                )
              ->Belt.Option.getWithDefault(Js.Promise.resolve()),
            _,
          )
      );
    };

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

    let getQueuePolicy = queueArn =>
      SQS.(
        sqsClient()
        ->getQueueAttributes(
            ~params=
              GetQueueAttributesRequest.make(
                ~_AttributeNames=[|"Policy"|],
                ~_QueueUrl=queueArn->arn2Url,
              ),
          )
        ->Request.promise
        ->Js.Promise.then_(
            response =>
              SQS.GetQueueAttributesResponse.(
                response
                ->getAttributes
                ->getPolicy
                ->unsafeParsePolicy
                ->Js.Promise.resolve
              ),
            _,
          )
      );

    let setQueuePolicy = (queueArn, policy: IAM.Policy.t) =>
      policy
      ->Js.Json.stringifyAny
      ->(
          fun
          | Some(newPolicy) =>
            SQS.(
              sqsClient()
              ->setQueueAttributes(
                  ~params=
                    SetQueueAttributesRequest.make(
                      ~_Attributes=
                        SetQueueAttributesRequest.Attributes.make(
                          ~_Policy=newPolicy,
                        ),
                      ~_QueueUrl=queueArn->arn2Url,
                    ),
                )
            )
            ->Request.promise
            ->Js.Promise.then_(_ => Js.Promise.resolve(), _)
          | None => Js.log("Couldn't stringify policy")->Js.Promise.resolve
        );

    let _addPermission = (sid, eventCollector, eventTopic) =>
      getQueuePolicy(eventCollector)
      ->Js.Promise.then_(
          policy =>
            eventCollector->setQueuePolicy(
              policy->addStatement(sid, eventCollector, eventTopic),
            ),
          _,
        );

    let _removePermission = (sid, eventCollector) =>
      getQueuePolicy(eventCollector)
      ->Js.Promise.then_(
          policy =>
            eventCollector->setQueuePolicy(policy->removeStatement(sid)),
          _,
        );

    let subscribe =
        (action, extensionPointName, eventTopic, pluginId, eventCollector) => {
      let eventTopicName = eventTopic->AWS.arn2Name;
      let eventCollectorName = eventCollector->AWS.arn2Name;
      let _sid = (extensionPointName ++ "-" ++ pluginId)->AWS.validateName;
      subscribeQueueToTopic(eventCollector, eventTopic)
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

      unsubscribeQueueFromTopic(eventCollector, eventTopic)
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
            ->Belt.Array.keepMap(({name: extensionPointName, eventTopic}) =>
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
            ->Belt.Array.keepMap(({name: extensionPointName, eventTopic}) =>
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
              | PluginDeactivated(pluginDef)
              | PluginDisconnected(pluginDef) when pluginId != id => [|
                  Call(callHandler, DoDisconnectPlugin(pluginDef)),
                |]
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
        ~queryCommandTopic,
        ~pluginExtensionPointCommandTopicId=corePluginCommandTopicId,
        ~queryEngine,
        ~opts=Some(opts),
        (),
      );

    let tasksOutputs = ref([||]);
    let queryBucketName =
      InterstackResourceQueryRuntime.bucketNameOfTaskExn(
        tasksOutputs->Interstack.mergeTasks,
      );
    let queryEventCollector = name =>
      (tasksOutputs^)
      ->Belt.Array.keepMap(output => output##sideEffectHandler)
      ->Belt.Array.getBy(sideEffectHandler => sideEffectHandler##name == name)
      ->Belt.Option.getExn##eventCollector##connector;

    tasksOutputs :=
      taskMakers->Belt.Array.map(taskMaker =>
        taskMaker(
          ~queryCommandTopic,
          ~queryEventCollector,
          ~queryEventTopic,
          ~queryBucketName,
          ~scheduler,
          ~queryEngine,
          ~opts=Some(opts),
        )
        ->Component.extractOutputs
      );

    let eventMappersOutputs =
      eventMapperMakers
      ->Belt.Array.map((eventMapperMaker: EventMapper.maker) =>
          eventMapperMaker(
            ~queryEngine,
            ~queryCommandTopic,
            ~queryEventTopic,
            ~memorySize=128,
            ~opts=Some(opts),
            (),
          )
        )
      ->Component.extractMultipleOutputs;

    let resolvers =
      servicesOutputs
      ->ResourceQueryDeploytime.allResolversMakers
      ->Belt.Array.map(resolverMaker => resolverMaker(queryQueryDbDeploytime))
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

    let aggregateNames: array(string) =
      extensionPointAggregateNames
      ->Belt.Array.concat(extensionAggregateNames)
      ->Belt.Array.reduce(Set.empty, Set.union)
      ->Belt.Set.String.toArray
      ->Belt.Array.concat([|ReventlessSpec.PluginExtensionPointSpec.name|]);

    let handleEvent = (event'Json, dict, getEventHandler) => {
      event'Json
      ->Message.serviceNameOfMsg
      ->Belt.Option.flatMap(serviceName => dict->Js.Dict.get(serviceName))
      ->Belt.Option.mapWithDefault(Js.Promise.resolve(), exs =>
          exs
          ->Belt.Array.map(ex =>
              (getEventHandler(ex))(.
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
            incomingServiceNameToExtensionsMapping->Js.Dict.get(serviceName),
            outgoingServiceNameToExtensionsMapping->Js.Dict.get(serviceName),
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

    let eventHandler =
      (. event'Json) => {
        event'Json->Message.logEvent'Json(
          {j|Plugin $id eventHandler: incoming event:|j},
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
                handleEvent(
                  event'Json,
                  serviceNameToExtensionPointsMapping,
                  extensionPoint =>
                  extensionPoint##outgoingEventHandler
                ),
                handleEvent(
                  event'Json, outgoingServiceNameToExtensionsMapping, extension =>
                  extension##outgoingEventHandler
                ),
                handleEvent(
                  event'Json, incomingServiceNameToExtensionsMapping, extension =>
                  extension##incomingEventHandler
                ),
              |]
              ->Js.Promise.all
              ->Js.Promise.then_(_ => Js.Promise.resolve(), _),
            _,
          );
      };

    module EventCollector =
      EventCollector.Make(
        EventCollector.DefaultPolicies,
        EventCollectorAdapter,
      );

    let eventCollector =
      EventCollector.make(
        ~name=name ++ componentType->ComponentType.toName,
        ~aggregateNames,
        ~eventHandler,
        ~queryEventTopic,
        ~opts=Some(opts),
        (),
      );
    let eventCollectorOutputs = eventCollector->Component.extractOutputs;
    setEventCollectorUrn(. eventCollectorOutputs##connector##urn);

    let heartbeat =
      Heartbeat.make(
        ~id,
        ~name=name ++ componentType->ComponentType.toName,
        ~timeout=heartbeatInterval,
        ~commandTopicId=corePluginCommandTopicId,
        ~opts,
        (),
      );

    makeOutputs(
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
    )
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
