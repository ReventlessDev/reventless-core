// TODO: refactor to smaller code parts for a better overview
open ReventlessSpec.Adapter;

let componentType = ComponentType.Plugin;

type outputs = {
  .
  "id": Pulumi.Output.t(string),
  "version": Pulumi.Output.t(string),
  "heartbeatInterval": Pulumi.Output.t(int),
  "eventCollector": Pulumi.Output.t(EventCollector.outputs),
  "extensionPoints": Pulumi.Output.t(Js.Dict.t(ExtensionPoint.outputs)),
  "extensions": Pulumi.Output.t(Js.Dict.t(Extension.outputs)),
  "aggregates": Pulumi.Output.t(Js.Dict.t(Aggregate.outputs)),
  "readModels": Pulumi.Output.t(Js.Dict.t(ReadModel.outputs)),
  "tasks": Pulumi.Output.t(Js.Dict.t(Task.outputs)),
  "resolvers": Pulumi.Output.t(array(resource)),
  "heartbeat": Pulumi.Output.t(Heartbeat.outputs),
  "serviceNameToExtensionPointsMapping":
    Pulumi.Output.t(Js.Dict.t(array(ExtensionPoint.outputs))),
  "outgoingServiceNameToExtensionsMapping":
    Pulumi.Output.t(Js.Dict.t(array(Extension.outputs))),
  "incomingServiceNameToExtensionsMapping":
    Pulumi.Output.t(Js.Dict.t(array(Extension.outputs))),
  "resources": Pulumi.Output.t(resources),
};

type t;
type component = Component.t(t, outputs);

type maker =
  (
    ~name: string,
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array(module ExtensionPoint.T),
    ~extensions: array(module Extension.T),
    ~aggregates: array(module Aggregate.T),
    ~readModels: array(module ReadModel.T),
    ~taskMakers: array(Task.maker),
    ~scheduler: Scheduler.t,
    ~opts: Pulumi.ComponentResource.Options.t=?,
    unit
  ) =>
  component;

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
  type construct = (component, string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    component =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~id: Pulumi.Output.t(string),
      ~version: Pulumi.Output.t(string),
      ~heartbeatInterval: Pulumi.Output.t(int),
      ~eventCollector: Pulumi.Output.t(EventCollector.outputs),
      ~extensionPoints: Pulumi.Output.t(Js.Dict.t(ExtensionPoint.outputs)),
      ~extensions: Pulumi.Output.t(Js.Dict.t(Extension.outputs)),
      ~aggregates: Pulumi.Output.t(Js.Dict.t(Aggregate.outputs)),
      ~readModels: Pulumi.Output.t(Js.Dict.t(ReadModel.outputs)),
      ~tasks: Pulumi.Output.t(Js.Dict.t(Task.outputs)),
      ~resolvers: Pulumi.Output.t(array(resource)),
      ~heartbeat: Pulumi.Output.t(Heartbeat.outputs),
      ~serviceNameToExtensionPointsMapping: Pulumi.Output.t(
                                              Js.Dict.t(
                                                array(ExtensionPoint.outputs),
                                              ),
                                            ),
      ~outgoingServiceNameToExtensionsMapping: Pulumi.Output.t(
                                                 Js.Dict.t(
                                                   array(Extension.outputs),
                                                 ),
                                               ),
      ~incomingServiceNameToExtensionsMapping: Pulumi.Output.t(
                                                 Js.Dict.t(
                                                   array(Extension.outputs),
                                                 ),
                                               ),
      ~resources: Pulumi.Output.t(resources)
    ) =>
    outputs =
    "";

  // TODO: find better naming
  type pureOutputs = {
    id: string,
    version: string,
    heartbeatInterval: int,
    eventCollector: EventCollector.outputs,
    extensionPoints: Js.Dict.t(ExtensionPoint.outputs),
    extensions: Js.Dict.t(Extension.outputs),
    aggregates: Js.Dict.t(Aggregate.outputs),
    readModels: Js.Dict.t(ReadModel.outputs),
    tasks: Js.Dict.t(Task.outputs),
    resolvers: array(resource),
    heartbeat: Heartbeat.outputs,
    serviceNameToExtensionPointsMapping:
      Js.Dict.t(array(ExtensionPoint.outputs)),
    outgoingServiceNameToExtensionsMapping:
      Js.Dict.t(array(Extension.outputs)),
    incomingServiceNameToExtensionsMapping:
      Js.Dict.t(array(Extension.outputs)),
    resources,
  };

  [@bs.send]
  external registerOutputs: (component, outputs) => constructed =
    "registerOutputs";
  [@bs.send] external setOutputs: (component, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  type readModel = {
    module_: (module ReadModel.T),
    readModel: ReadModel.component,
  };

  let construct =
      (
        ~version: string,
        ~heartbeatInterval: int,
        ~extensionPoints: array(module ExtensionPoint.T),
        ~extensions: array(module Extension.T),
        ~aggregates: array(module Aggregate.T),
        ~readModels: array(module ReadModel.T),
        ~taskMakers: array(Task.maker),
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

    let readModels =
      readModels
      ->Belt.Array.map((module ReadModel: ReadModel.T) =>
          (
            ReadModel.Spec.name,
            {
              module_: (module ReadModel),
              readModel: ReadModel.make(~opts, ~resources, ()),
            },
          )
        )
      ->Js.Dict.fromArray;
    let readModelsOutputs =
      readModels
      ->Js.Dict.values
      ->Belt.Array.map(({readModel}) => readModel)
      ->Component.extractMultipleOutputs;

    let queryEngine = QueryEngineAdapter.make(resources);

    let addEventMapperFns = Js.Dict.empty();
    let publishJsonsFns = Js.Dict.empty();
    let aggregatesWithoutEventMappers =
      aggregates
      ->Belt.Array.map((module Aggregate: Aggregate.T) => {
          let {module_, readModel} =
            readModels->Js.Dict.unsafeGet(Aggregate.Spec.name);
          module ReadModel = (val module_);
          let aggregate =
            Aggregate.make(
              ~queryEngine,
              ~eventsHandler=
                (. id, events) =>
                  readModel->ReadModel.update(.
                    id->Obj.magic,
                    events->Obj.magic,
                  ), // TODO : remove
              ~opts,
              ~resources,
              (),
            );
          addEventMapperFns->Js.Dict.set(
            Aggregate.Spec.name,
            Aggregate.addEventMapper(aggregate),
          );
          publishJsonsFns->Js.Dict.set(
            Aggregate.Spec.name,
            Aggregate.publishJsons(aggregate),
          );
          aggregate->Component.extractOutputs;
        })
      ->toDict;
    let aggregatesOutputs =
      Js.Dict.map(
        (. addEventMapperFn) =>
          addEventMapperFn(aggregatesWithoutEventMappers),
        addEventMapperFns,
      );

    let pureOutputs =
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
            corePluginExtensionPoint##commandTopic##resources[0] // FIXME: hardcoded resource
            ->Obj.magic // StackReference outputs are not wrapped in Pulumi.Outputs !
            ->Adapter.toResource;
          let corePluginCommandTopicId = corePluginCommandTopic##id;

          resources->Util.ExtensionPoint.setCommandTopicConnectorResource(
            corePluginCommandTopic,
            ReventlessSpec.PluginExtensionPointSpec.name,
          );
          resources->Util.ExtensionPoint.setEventTopicPublisherResource(
            corePluginExtensionPoint##eventTopic##resources[0] // FIXME
            ->Obj.magic // StackReference outputs are not wrapped in Pulumi.Outputs !
            ->Adapter.toResource,
            ReventlessSpec.PluginExtensionPointSpec.name,
          );

          let extensionPoints =
            extensionPoints->Belt.Array.map(
              (module ExtensionPoint: ExtensionPoint.T) =>
              ExtensionPoint.make(
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
            extensions->Belt.Array.map((module Extension: Extension.T) =>
              Extension.make(
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
              (
                action,
                extensionPointName,
                eventTopic,
                pluginId,
                eventCollector,
              ) => {
            let eventTopicName = eventTopic->AWS.arn2Name;
            let eventCollectorName = eventCollector->AWS.arn2Name;
            let _sid =
              (extensionPointName ++ "-" ++ pluginId)->AWS.validateName;
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
              (
                action,
                extensionPointName,
                eventTopic,
                pluginId,
                eventCollector,
              ) => {
            let eventTopicName = eventTopic->AWS.arn2Name;
            let eventCollectorName = eventCollector->AWS.arn2Name;
            let _sid =
              (extensionPointName ++ "-" ++ pluginId)->AWS.validateName;

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
                id: otherPluginId,
                extensionPoints: otherPluginExtensionPoints,
                extensions: otherPluginExtensions,
                eventCollector: otherPluginEventCollector,
              }) => {
                /* Current Plugin received `PluginConnected`:
                 *  this means: current plugin was already deployed before and received plugin just has been deployed
                 * - connectToExtensionPoints: if the newly deployed (received) plugin contains extensionpoints
                 *    the current plugin relies on: connect current plugin to received plugin extension point's eventTopic
                 * - if the newly deployed (received) plugin contains extensions the current plugin holds an extensionpoint for:
                 *    connect received extensions to current plugin's extension point
                 */
                let connectToExtensionPoints =
                  otherPluginExtensionPoints
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
                      otherPluginExtensions
                      ->Belt.Array.keep(({extensionPointName}) =>
                          extensionPoint##name == extensionPointName
                        )
                      ->Belt.Array.length
                      > 0
                        ? Some(
                            subscribe(
                              "connectToExtensions",
                              extensionPoint##name,
                              extensionPoint##eventTopic##resources[0]##id // FIXME
                              ->Pulumi.Output.get,
                              otherPluginId,
                              otherPluginEventCollector,
                            ),
                          )
                        : None
                    )
                  ->Js.Promise.all
                  ->Js.Promise.then_(_ => Js.Promise.resolve(), _);

                // await connections of extensionpoints & extensions
                Js.Promise.all2((
                  connectToExtensionPoints,
                  connectToExtensions,
                ))
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
                              extensionPoint##eventTopic##resources[0]##id // FIXME
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
                  extensionPoint##commandTopic##resources[0]##id, // FIXME
                  extensionPoint##eventTopic##resources[0]##id,
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
            ->Pulumi.Output.apply(
                ((extensionPointsConfig, eventCollectorUrn)) =>
                {
                  PluginSpec.id,
                  name,
                  version,
                  extensionPoints: extensionPointsConfig,
                  extensions: extensionsConfig,
                  eventCollector: eventCollectorUrn,
                }
              );

          module ConnectPluginMapping =
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

          module ConnectPluginMappings = {
            module Spec = ReventlessSpec.PluginExtensionPointSpec;
            module type Mapping =
              ExtensionMapping.T with module ExtensionPoint := Spec;
            let name = "Connect";
            let mappings: array(module Mapping) = [|
              (module ConnectPluginMapping),
            |];
          };

          module ConnectPluginExtension =
            Extension.Make(
              ReventlessSpec.PluginExtensionPointSpec,
              ConnectPluginMappings,
            );

          let connectPluginExtension =
            ConnectPluginExtension.make(
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

          let resolvers =
            readModelsOutputs
            ->ResourceQueryDeploytime.allResolversMakers
            ->Belt.Array.map(resolverMaker => resolverMaker(resources))
            ->Belt.Array.concatMany;

          module Set = Belt.Set.String;

          let collectAggregateNames = exs =>
            exs
            ->Belt.Array.map(ex =>
                ex##aggregateNames
                ->Set.fromArray
                ->Set.remove(ReventlessSpec.ExtensionMapping.NoAggregate.name)
              )
            ->Belt.Array.reduce(Set.empty, Set.union);

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

          let extensionAggregateNames =
            extensionsOutputs->collectAggregateNames;

          let handleEvent = (event'Json, dict, getEventHandler) => {
            event'Json
            ->Message.serviceNameOfMsg
            ->Belt.Option.flatMap(serviceName =>
                dict->Js.Dict.get(serviceName)
              )
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
                  serviceNameToExtensionPointsMapping->Js.Dict.get(
                    serviceName,
                  ),
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

          let eventTopics =
            Util.Aggregate.findEventTopics(
              aggregatesOutputs,
              extensionPointAggregateNames->Set.union(
                extensionAggregateNames,
              ),
            );
          eventTopics->Js.Dict.set(
            ReventlessSpec.PluginExtensionPointSpec.name,
            corePluginExtensionPoint##eventTopic,
          );

          let eventCollector =
            EventCollector.make(
              ~name=name->ComponentType.name(componentType),
              ~eventTopics,
              ~eventsHandler,
              ~opts=Some(opts),
              (),
            );
          let eventCollectorOutputs = eventCollector->Component.extractOutputs;
          setEventCollectorUrn(. eventCollectorOutputs##resources[0]##urn); //FIXME

          let heartbeat =
            Heartbeat.make(
              ~id,
              ~name=name ++ componentType->ComponentType.toName,
              ~timeout=heartbeatInterval,
              ~commandTopicId=corePluginCommandTopicId,
              ~opts,
              (),
            );

          {
            id,
            version,
            heartbeatInterval,
            eventCollector: eventCollectorOutputs,
            extensionPoints: extensionPointsOutputs->toDict,
            extensions: extensionsOutputs->toDict,
            aggregates: aggregatesOutputs,
            readModels: readModelsOutputs->toDict,
            tasks: (tasksOutputs^)->toDict,
            resolvers,
            heartbeat: heartbeat->Component.extractOutputs,
            serviceNameToExtensionPointsMapping,
            outgoingServiceNameToExtensionsMapping,
            incomingServiceNameToExtensionsMapping,
            resources,
          };
        });
    makeOutputs(
      ~id=pureOutputs->Pulumi.Output.apply(outputs => outputs.id),
      ~version=pureOutputs->Pulumi.Output.apply(outputs => outputs.version),
      ~heartbeatInterval=
        pureOutputs->Pulumi.Output.apply(outputs => outputs.heartbeatInterval),
      ~eventCollector=
        pureOutputs->Pulumi.Output.apply(outputs => outputs.eventCollector),
      ~extensionPoints=
        pureOutputs->Pulumi.Output.apply(outputs => outputs.extensionPoints),
      ~extensions=
        pureOutputs->Pulumi.Output.apply(outputs => outputs.extensions),
      ~aggregates=
        pureOutputs->Pulumi.Output.apply(outputs => outputs.aggregates),
      ~readModels=
        pureOutputs->Pulumi.Output.apply(outputs => outputs.readModels),
      ~tasks=pureOutputs->Pulumi.Output.apply(outputs => outputs.tasks),
      ~resolvers=
        pureOutputs->Pulumi.Output.apply(outputs => outputs.resolvers),
      ~heartbeat=
        pureOutputs->Pulumi.Output.apply(outputs => outputs.heartbeat),
      ~serviceNameToExtensionPointsMapping=
        pureOutputs->Pulumi.Output.apply(outputs =>
          outputs.serviceNameToExtensionPointsMapping
        ),
      ~outgoingServiceNameToExtensionsMapping=
        pureOutputs->Pulumi.Output.apply(outputs =>
          outputs.outgoingServiceNameToExtensionsMapping
        ),
      ~incomingServiceNameToExtensionsMapping=
        pureOutputs->Pulumi.Output.apply(outputs =>
          outputs.incomingServiceNameToExtensionsMapping
        ),
      ~resources=
        pureOutputs->Pulumi.Output.apply(outputs => outputs.resources),
    )
    ->setOutputs(self, _);
  };

  let make: maker =
    (
      ~name,
      ~version,
      ~heartbeatInterval,
      ~extensionPoints,
      ~extensions,
      ~aggregates,
      ~readModels,
      ~taskMakers,
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
            ~extensionPoints,
            ~extensions,
            ~aggregates,
            ~readModels,
            ~taskMakers,
            ~scheduler,
          ),
        ~opts,
      );
};
