// TODO: refactor to smaller code parts for a better overview
open ReventlessSpec.Adapter

let componentType = ComponentType.Plugin

type outputs = {
  "id": Pulumi.Output.t<string>,
  "version": Pulumi.Output.t<string>,
  "heartbeatInterval": Pulumi.Output.t<int>,
  "eventCollector": Pulumi.Output.t<ReventlessSpec.EventCollector.outputs>,
  "extensionPoints": Pulumi.Output.t<Js.Dict.t<ReventlessSpec.ExtensionPoint.outputs>>,
  "extensions": Pulumi.Output.t<Js.Dict.t<Extension.outputs>>,
  "aggregates": Pulumi.Output.t<Js.Dict.t<Aggregate.outputs>>,
  "readModels": Pulumi.Output.t<Js.Dict.t<ReventlessSpec.ReadModel.outputs>>,
  "tasks": Pulumi.Output.t<Js.Dict.t<Task.outputs>>,
  "resolvers": Pulumi.Output.t<array<resource>>,
  "heartbeat": Pulumi.Output.t<Heartbeat.outputs>,
  "serviceNameToExtensionPointsMapping": Pulumi.Output.t<
    Js.Dict.t<array<ReventlessSpec.ExtensionPoint.outputs>>,
  >,
  "outgoingServiceNameToExtensionsMapping": Pulumi.Output.t<Js.Dict.t<array<Extension.outputs>>>,
  "incomingServiceNameToExtensionsMapping": Pulumi.Output.t<Js.Dict.t<array<Extension.outputs>>>,
  "readModelNamesForSourceName": Pulumi.Output.t<Js.Dict.t<array<string>>>,
}

type t
type component = ReventlessSpec.Component.t<t, outputs>

module type T = {
  let make: (
    ~name: string,
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ReventlessSpec.ExtensionPoint.T)>,
    ~extensions: array<module(Extension.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReventlessSpec.ReadModel.T)>,
    ~taskMakers: array<Task.maker>,
    ~scheduler: ReventlessSpec.Scheduler.t,
    ~opts: Pulumi.ComponentResource.Options.t=?,
    unit,
  ) => component
}

let toDict = els => els->Belt.Array.map(el => (el["name"], el))->Js.Dict.fromArray

let makeId = (name, version) => `${name}@${version}`

module Make = (
  EventCollectorConnector: EventCollector.Adapter.Connector,
  QueryEngineAdapter: QueryDb.Adapter.QueryEngineAdapter,
  CorePluginExtensionPointRemoteConnector: CommandTopic.Adapter.RemoteConnector,
): T => {
  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
  ) => component = "default"

  @obj
  external makeOutputs: (
    ~id: Pulumi.Output.t<string>,
    ~version: Pulumi.Output.t<string>,
    ~heartbeatInterval: Pulumi.Output.t<int>,
    ~eventCollector: Pulumi.Output.t<ReventlessSpec.EventCollector.outputs>,
    ~extensionPoints: Pulumi.Output.t<Js.Dict.t<ReventlessSpec.ExtensionPoint.outputs>>,
    ~extensions: Pulumi.Output.t<Js.Dict.t<Extension.outputs>>,
    ~aggregates: Pulumi.Output.t<Js.Dict.t<Aggregate.outputs>>,
    ~readModels: Pulumi.Output.t<Js.Dict.t<ReventlessSpec.ReadModel.outputs>>,
    ~tasks: Pulumi.Output.t<Js.Dict.t<Task.outputs>>,
    ~resolvers: Pulumi.Output.t<array<resource>>,
    ~heartbeat: Pulumi.Output.t<Heartbeat.outputs>,
    ~serviceNameToExtensionPointsMapping: Pulumi.Output.t<
      Js.Dict.t<array<ReventlessSpec.ExtensionPoint.outputs>>,
    >,
    ~outgoingServiceNameToExtensionsMapping: Pulumi.Output.t<Js.Dict.t<array<Extension.outputs>>>,
    ~incomingServiceNameToExtensionsMapping: Pulumi.Output.t<Js.Dict.t<array<Extension.outputs>>>,
    ~readModelNamesForSourceName: Pulumi.Output.t<Js.Dict.t<array<string>>>,
  ) => outputs = ""

  // TODO: find better naming
  type pureOutputs = {
    id: string,
    version: string,
    heartbeatInterval: int,
    eventCollector: ReventlessSpec.EventCollector.outputs,
    extensionPoints: Js.Dict.t<ReventlessSpec.ExtensionPoint.outputs>,
    extensions: Js.Dict.t<Extension.outputs>,
    aggregates: Js.Dict.t<Aggregate.outputs>,
    readModels: Js.Dict.t<ReventlessSpec.ReadModel.outputs>,
    tasks: Js.Dict.t<Task.outputs>,
    resolvers: array<resource>,
    heartbeat: Heartbeat.outputs,
    serviceNameToExtensionPointsMapping: Js.Dict.t<array<ReventlessSpec.ExtensionPoint.outputs>>,
    outgoingServiceNameToExtensionsMapping: Js.Dict.t<array<Extension.outputs>>,
    incomingServiceNameToExtensionsMapping: Js.Dict.t<array<Extension.outputs>>,
    readModelNamesForSourceName: Js.Dict.t<array<string>>,
  }

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  type readModel = {
    module_: module(ReventlessSpec.ReadModel.T),
    readModel: ReventlessSpec.ReadModel.component,
  }

  let construct = (
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ReventlessSpec.ExtensionPoint.T)>,
    ~extensions: array<module(Extension.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReventlessSpec.ReadModel.T)>,
    ~taskMakers: array<Task.maker>,
    ~scheduler: ReventlessSpec.Scheduler.t,
    self,
    name,
  ) => {
    let id = makeId(name, version)

    let opts = Pulumi.ComponentResource.Options.make(~parent=self->Component.toPulumiResource, ())

    let addEventMapperFns = Js.Dict.empty()
    let publishToAggregates = Js.Dict.empty()

    let aggregatesWithoutEventMappers =
      aggregates
      ->Belt.Array.map((module(Aggregate: Aggregate.T)) => {
        let aggregate = Aggregate.make(~opts, ())
        addEventMapperFns->Js.Dict.set(Aggregate.Spec.name, aggregate->Aggregate.addEventMapper)
        publishToAggregates->Js.Dict.set(Aggregate.Spec.name, aggregate->Aggregate.publishJsons)
        aggregate->Component.extractOutputs
      })
      ->toDict

    let allEventTopics = Util.Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    let readModelNamesForSourceName = Js.Dict.empty()
    let publishToReadModels = Js.Dict.empty()

    let readModels = readModels->Belt.Array.map((module(ReadModel: ReventlessSpec.ReadModel.T)) => {
      let readModel = ReadModel.make(~allEventTopics, ~opts, ())
      ReadModel.sourceNames->Belt.Array.forEach(sourceName =>
        switch readModelNamesForSourceName->Js.Dict.get(sourceName) {
        | Some(readModelNames) =>
          Js.Dict.set(
            readModelNamesForSourceName,
            sourceName,
            readModelNames->Belt.Array.concat([ReadModel.Spec.name]),
          )
        | None => Js.Dict.set(readModelNamesForSourceName, sourceName, [ReadModel.Spec.name])
        }
      )
      publishToReadModels->Js.Dict.set(ReadModel.Spec.name, readModel->ReadModel.enqueueEvent)

      (ReadModel.Spec.name, {module_: module(ReadModel), readModel})
    })
    let readModelsOutputs =
      readModels
      ->Js.Dict.fromArray
      ->Js.Dict.entries
      ->Belt.Array.map(((name, {readModel})) => (name, readModel->Component.extractOutputs))
      ->Js.Dict.fromArray

    let allQueryDbs = readModelsOutputs->Util.ReadModel.allQueryDbs
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    let aggregatesOutputs = Js.Dict.map(
      (. addEventMapperFn) => addEventMapperFn(allEventTopics, queryEngine),
      addEventMapperFns,
    )

    let extensionPoints =
      extensionPoints->Belt.Array.map((module(ExtensionPoint: ReventlessSpec.ExtensionPoint.T)) =>
        ExtensionPoint.make(~publishToAggregates, ~scheduler, ~queryEngine, ~opts=Some(opts), ())
      )
    let extensionPointsOutputs = extensionPoints->Component.extractMultipleOutputs

    let pureOutputs = {
      let coreExtensionPoints =
        Interstack.coreStackReference->Belt.Option.mapWithDefault(
          Pulumi.Output.make(None),
          coreStack => coreStack->Pulumi.StackReference.getOutput("extensionPoints"),
        )

      /*
       (
         switch (
                   ) {
         | Some(coreExtensionPoints) => coreExtensionPoints
         | None =>
           Js.Exn.raiseError(
             "No Core Stack configured or no Core ExtensionPoints! (Please set 'core:stack: user/project/stack' in you Pulumi.*.config!",
           )
         }
       )
 */

      coreExtensionPoints->Pulumi.Output.apply(coreExtensionPoints => {
        let coreExtensionPoints = switch coreExtensionPoints {
        | Some(coreExtensionPoints) => coreExtensionPoints
        | None =>
          Js.Exn.raiseError(
            "No Core Stack configured or no Core ExtensionPoints! (Please set 'core:stack: user/project/stack' in you Pulumi.*.config!",
          )
        }
        open Pulumi.StackReference.Infix
        let corePluginExtensionPoint = \"-#"(
          coreExtensionPoints,
          ReventlessSpec.PluginExtensionPointSpec.name,
        )

        let corePluginExtensionPointCommandTopicRemoteConnector = CorePluginExtensionPointRemoteConnector.make(
          corePluginExtensionPoint["commandTopic"],
        )
        let publishToCorePluginExtensionPoint = corePluginExtensionPointCommandTopicRemoteConnector.remotePublish

        let extensions =
          extensions->Belt.Array.map((module(Extension: Extension.T)) =>
            Extension.make(
              ~publishToCorePluginExtensionPoint,
              ~publishToAggregates,
              ~readModelNamesForSourceName,
              ~publishToReadModels,
              ~queryEngine,
              ~opts=Some(opts),
              (),
            )
          )
        let extensionsOutputs = extensions->Component.extractMultipleOutputs

        let (eventCollectorUrn, setEventCollectorUrn) = Util.Pulumi.Output.Async.make()
        open AwsSdk

        let addStatement = (policy: IAM.Policy.t, sid, queueArn, topicArn) => {
          let newStatements =
            policy.statement
            ->Belt.Array.keep(statement => statement.sid != sid)
            ->Belt.Array.concat([
              {
                IAM.Policy.sid,
                effect: "Allow",
                principal: "*",
                action: "sqs:SendMessage",
                resource: queueArn,
                condition: {IAM.Policy.arnEquals: topicArn},
              },
            ])
          Js.log(`addStatement: adding 1 statement with Sid ${sid}`)
        { IAM.Policy.version:policy.version,
            id:policy.id,
            statement:newStatements,
          }
        }

        let removeStatement: (IAM.Policy.t, string)=> IAM.Policy.t = (policy, sid) => {
          let statements = policy.statement
          let newStatements = statements->Belt.Array.keep(statement => statement.sid != sid)
          let removedStatements = statements->Belt.Array.length - newStatements->Belt.Array.length
          Js.log(
            `removeStatement: removing ${removedStatements->Belt.Int.toString} statement(s) with Sid ${sid}`,
          )
                        {IAM.Policy.version:policy.version,
            id:policy.id,
            statement:newStatements,
          }
        }

        let _addPermission = async (sid, eventCollector, eventTopic) =>
          switch await SQS.getQueuePolicy(eventCollector) {
          | policy =>
            eventCollector->SQS.setQueuePolicy(
              policy->addStatement(sid, eventCollector, eventTopic),
            )
          }

        let _removePermission = async (sid, eventCollector) =>
          switch await SQS.getQueuePolicy(eventCollector) {
          | policy => eventCollector->SQS.setQueuePolicy(policy->removeStatement(sid))
          }

        let subscribe = async (
          action,
          extensionPointName,
          eventTopic,
          pluginId,
          eventCollector,
        ) => {
          let eventTopicName = eventTopic->AWS.arn2Name
          let eventCollectorName = eventCollector->AWS.arn2Name
          let _sid = (extensionPointName ++ ("-" ++ pluginId))->AWS.validateName

          Js.log(
            `Trying to ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`,
          )
          switch await SNS.subscribeQueueToTopic(eventCollector, eventTopic) {
          | _ =>
            Js.log(
              `Successful ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`,
            )
          | exception Js.Exn.Error(e) =>
            Js.log2(
              `Could not ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName}):`,
              e,
            )
          }
        }

        let unsubscribe = async (
          action,
          extensionPointName,
          eventTopic,
          pluginId,
          eventCollector,
        ) => {
          let eventTopicName = eventTopic->AWS.arn2Name
          let eventCollectorName = eventCollector->AWS.arn2Name
          let _sid = (extensionPointName ++ ("-" ++ pluginId))->AWS.validateName

          Js.log(
            `Trying to ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`,
          )
          switch await SNS.unsubscribeQueueFromTopic(eventCollector, eventTopic) {
          | _ =>
            Js.log(
              `Success: ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`,
            )
          | exception Js.Exn.Error(e) =>
            Js.log2(
              `Could not ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName}):`,
              e,
            )
          }
        }

        let callHandler = async command =>
          switch command {
          | ReventlessSpec.PluginExtensionPointSpec.DoConnectPlugin({
              id: otherPluginId,
              extensionPoints: otherPluginExtensionPoints,
              extensions: otherPluginExtensions,
              eventCollector: otherPluginEventCollector,
            }) =>
            /* Current Plugin received `PluginConnected`:
             *  this means: current plugin was already deployed before and received plugin just has been deployed
             * - connectToExtensionPoints: if the newly deployed (received) plugin contains extensionpoints
             *    the current plugin relies on: connect current plugin to received plugin extension point's eventTopic
             * - if the newly deployed (received) plugin contains extensions the current plugin holds an extensionpoint for:
             *    connect received extensions to current plugin's extension point
             */
            let connectToExtensionPoints =
              otherPluginExtensionPoints
              ->Message.log("otherPluginExtensionPoints:")
              ->Belt.Array.keepMap(({name: extensionPointName, eventTopic}) =>
                extensionsOutputs
                ->Belt.Array.keep(
                  extension => extension["extensionPointName"] == extensionPointName,
                )
                ->Message.log("matching Extensions:")
                ->Belt.Array.length > 0
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

            let connectToExtensions =
              extensionPointsOutputs
              ->Message.log("extensionPoints:")
              ->Belt.Array.keepMap(extensionPoint =>
                otherPluginExtensions
                ->Belt.Array.keep(
                  ({extensionPointName}) => extensionPoint["name"] == extensionPointName,
                )
                ->Message.log("matching otherPluginExtensions:")
                ->Belt.Array.length > 0
                  ? Some(
                      subscribe(
                        "connectToExtensions",
                        extensionPoint["name"],
                        extensionPoint["eventTopic"]["resources"][0]["id"]->Pulumi.Output.get, // FIXME
                        otherPluginId,
                        otherPluginEventCollector,
                      ),
                    )
                  : None
              )

            await connectToExtensionPoints
            ->Belt.Array.concat(connectToExtensions)
            ->Js.Promise.all
            ->Util.Promise.toUnit

          | DoDisconnectPlugin({
              id: pluginId,
              extensionPoints: pluginExtensionPoints,
              extensions: pluginExtensions,
              eventCollector: pluginEventCollector,
            }) =>
            let disconnectFromExtensionPoints =
              pluginExtensionPoints->Belt.Array.keepMap(({name: extensionPointName, eventTopic}) =>
                extensionsOutputs
                ->Belt.Array.keep(
                  extension => extension["extensionPointName"] == extensionPointName,
                )
                ->Belt.Array.length > 0
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

            let disconnectFromExtensions =
              extensionPointsOutputs->Belt.Array.keepMap(extensionPoint =>
                pluginExtensions
                ->Belt.Array.keep(
                  ({extensionPointName}) => extensionPoint["name"] == extensionPointName,
                )
                ->Belt.Array.length > 0
                  ? Some(
                      unsubscribe(
                        "disconnectFromExtensions",
                        extensionPoint["name"],
                        extensionPoint["eventTopic"]["resources"][0]["id"]->Pulumi.Output.get, // FIXME
                        pluginId,
                        pluginEventCollector,
                      ),
                    )
                  : None
              )

            await disconnectFromExtensionPoints
            ->Belt.Array.concat(disconnectFromExtensions)
            ->Js.Promise.all
            ->Util.Promise.toUnit

          | _ => ()
          }

        let extensionPointsConfig =
          extensionPointsOutputs
          ->Belt.Array.map(extensionPoint =>
            (
              extensionPoint["commandTopic"]["resources"][0]["id"], // FIXME
              extensionPoint["eventTopic"]["resources"][0]["id"],
            )
            ->Pulumi.Output.all2
            ->Pulumi.Output.apply(
              ((commandTopicConnectorId, eventTopicPublisherId)) => {
                ReventlessSpec.Plugin.name: extensionPoint["name"],
                commandTopic: commandTopicConnectorId,
                eventTopic: eventTopicPublisherId,
              },
            )
          )
          ->Pulumi.Output.all

        let extensionsConfig = extensionsOutputs->Belt.Array.map(extension => {
          ReventlessSpec.Plugin.name: extension["name"],
          extensionPointName: extension["extensionPointName"],
        })

        let pluginDefinition =
          (extensionPointsConfig, eventCollectorUrn)
          ->Pulumi.Output.all2
          ->Pulumi.Output.apply(((extensionPointsConfig, eventCollectorUrn)) => {
            ReventlessSpec.Plugin.id,
            name,
            version,
            extensionPoints: extensionPointsConfig,
            extensions: extensionsConfig,
            eventCollector: eventCollectorUrn,
          })

        module ConnectPluginMapping = ExtensionMapping.Make(
          ReventlessSpec.PluginExtensionPointSpec,
          {
            module Aggregate = ReventlessSpec.ExtensionMapping.NoAggregate

            let mapIncomingEvent: ReventlessSpec.ExtensionMapping.mapIncomingEvent<
              ReventlessSpec.PluginExtensionPointSpec.event,
              Aggregate.command,
              ReventlessSpec.PluginExtensionPointSpec.command,
              ReventlessSpec.PluginExtensionPointSpec.callCommand,
            > = (pluginId, event, _meta, _pluginDef, _queryEngine) =>
              switch event {
              | ReventlessSpec.PluginExtensionPointSpec.UnknownPluginDetected if pluginId == id => [
                  PublishExtensionPointCommand(
                    id,
                    ReventlessSpec.PluginExtensionPointSpec.ConnectPlugin(
                      pluginDefinition->Pulumi.Output.get,
                    ),
                  ),
                ]
              | PluginConnected(pluginDef)
              | PluginReconnected(pluginDef) if pluginId != id => [
                  Call(callHandler, DoConnectPlugin(pluginDef)),
                ]
              | PluginDeactivated(pluginDef) if pluginId != id => [
                  Call(callHandler, DoDisconnectPlugin(pluginDef)),
                ]
              // don't disconnect because a newer version might be already connected
              // if the old version gets destroyed, then the subscription is also destroyed
              | PluginDisconnected(_) => []
              | _ => []
              }

            let mapOutgoingEvent = None
          },
        )

        module ConnectPluginMappings = {
          module Spec = ReventlessSpec.PluginExtensionPointSpec
          module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
          let name = "Connect"
          let mappings: array<module(Mapping)> = [module(ConnectPluginMapping)]
        }

        module ConnectPluginExtension = Extension.Make(
          ReventlessSpec.PluginExtensionPointSpec,
          ConnectPluginMappings,
        )

        let connectPluginExtension = ConnectPluginExtension.make(
          ~publishToCorePluginExtensionPoint,
          ~publishToAggregates,
          ~readModelNamesForSourceName,
          ~publishToReadModels,
          ~queryEngine,
          ~opts=Some(opts),
          (),
        )

        let tasksOutputs = ref([])
        let queryBucketName = taskName =>
          ResourceQueryRuntime.bucketNameOfTaskExn(tasksOutputs.contents, taskName)

        tasksOutputs :=
          taskMakers->Belt.Array.map(taskMaker =>
            taskMaker(
              ~queryBucketName,
              ~scheduler,
              ~publishToAggregates,
              ~queryEngine,
              ~allAggregates=aggregatesOutputs,
              ~opts=Some(opts),
            )->Component.extractOutputs
          )

        let allQueryDbs = readModelsOutputs->Util.ReadModel.allQueryDbs
        let resolvers =
          allQueryDbs
          ->Util.QueryDb.allResolversMakers
          ->Belt.Array.map(resolverMaker => resolverMaker(allQueryDbs))
          ->Belt.Array.concatMany

        module Set = Belt.Set.String

        let collectAggregateNames = exs =>
          exs
          ->Belt.Array.map(ex =>
            ex["aggregateNames"]
            ->Set.fromArray
            ->Set.remove(ReventlessSpec.ExtensionMapping.NoAggregate.name)
          )
          ->Belt.Array.reduce(Set.empty, Set.union)

        let extensionPointAggregateNames = extensionPointsOutputs->collectAggregateNames

        let serviceNameToComponent = (components, getServiceNames) => {
          let dict = Js.Dict.empty()
          components->Belt.Array.forEach(component =>
            component
            ->getServiceNames
            ->Belt.Array.forEach(
              serviceName =>
                switch dict->Js.Dict.get(serviceName) {
                | Some(mappedExtensionPoints) =>
                  Js.Dict.set(
                    dict,
                    serviceName,
                    mappedExtensionPoints->Belt.Array.concat([component]),
                  )
                | None => Js.Dict.set(dict, serviceName, [component])
                },
            )
          )
          dict
        }

        let incomingServiceNameToPluginConnectExtensionsMapping = serviceNameToComponent(
          [connectPluginExtension->Component.extractOutputs],
          extension => [extension["extensionPointName"]],
        )
        let serviceNameToExtensionPointsMapping = serviceNameToComponent(
          extensionPointsOutputs,
          extensionPoint => extensionPoint["aggregateNames"],
        )
        let outgoingServiceNameToExtensionsMapping = serviceNameToComponent(
          extensionsOutputs,
          extension => extension["aggregateNames"],
        )
        let incomingServiceNameToExtensionsMapping = serviceNameToComponent(
          extensionsOutputs,
          extension => [extension["extensionPointName"]],
        )

        let extensionAggregateNames = extensionsOutputs->collectAggregateNames

        let handleEvent = async (event'Json, dict, getEventHandler) => {
          await event'Json
          ->Message.serviceNameOfMsg
          ->Belt.Option.flatMap(serviceName => dict->Js.Dict.get(serviceName))
          ->Belt.Option.mapWithDefault(Js.Promise.resolve(), async components => {
            await components
            ->Belt.Array.map(
              component =>
                getEventHandler(component)(. event'Json, pluginDefinition->Pulumi.Output.get),
            )
            ->Js.Promise.all
            ->Util.Promise.toUnit
          })
        }

        let detectUnhandledEvent = event'Json =>
          event'Json
          ->Message.serviceNameOfMsg
          ->Belt.Option.mapWithDefault((), serviceName =>
            switch (
              serviceNameToExtensionPointsMapping->Js.Dict.get(serviceName),
              incomingServiceNameToExtensionsMapping->Js.Dict.get(serviceName),
              outgoingServiceNameToExtensionsMapping->Js.Dict.get(serviceName),
            ) {
            | (None, None, None) => Js.log("No mapping matches service name")
            | _ => ()
            }
          )

        let eventsHandler = (. events'Json) => {
          let count = events'Json->Belt.Array.size
          events'Json
          ->Belt.Array.mapWithIndex(async (idx, event'Json) => {
            let idx = idx + 1
            event'Json->Logger.logEvent'Json(
              `Plugin ${id} eventsHandler: incoming event ${idx->Belt.Int.toString}/${count->Belt.Int.toString}:`,
            )
            detectUnhandledEvent(event'Json)
            switch await handleEvent(
              event'Json,
              incomingServiceNameToPluginConnectExtensionsMapping,
              extension => extension["incomingEventHandler"],
            ) {
            | _ =>
              [
                event'Json->handleEvent(
                  serviceNameToExtensionPointsMapping,
                  extensionPoint => extensionPoint["outgoingEventHandler"],
                ),
                event'Json->handleEvent(
                  outgoingServiceNameToExtensionsMapping,
                  extension => extension["outgoingEventHandler"],
                ),
                event'Json->handleEvent(
                  incomingServiceNameToExtensionsMapping,
                  extension => extension["incomingEventHandler"],
                ),
              ]->Js.Promise.all
            }
          })
          ->Js.Promise.all
          ->Util.Promise.toUnit
        }

        module EventCollector = EventCollector.Make(EventCollectorConnector)

        let eventTopics =
          aggregatesOutputs->Util.Aggregate.filterEventTopics(
            extensionPointAggregateNames->Set.union(extensionAggregateNames),
          )
        eventTopics->Js.Dict.set(
          ReventlessSpec.PluginExtensionPointSpec.name,
          {
            "resources": corePluginExtensionPoint["eventTopic"]["resources"]->Belt.Array.map(
              AdapterDeploytime.stackRefResourceToResource,
            ),
          },
        )

        let eventCollector = EventCollector.make(
          ~name=name->ComponentType.name(componentType),
          ~eventTopics,
          ~eventsHandler,
          ~policy1=Pulumi.Output.make(None),
          ~policy2=Pulumi.Output.make(None),
          ~opts=Some(opts),
          (),
        )
        let eventCollectorOutputs = eventCollector->Component.extractOutputs
        setEventCollectorUrn(. eventCollectorOutputs["resources"][0]["urn"]) //FIXME

        let heartbeat = Heartbeat.make(
          ~id,
          ~name=name ++ componentType->ComponentType.toName,
          ~timeout=heartbeatInterval,
          ~publishToCorePluginExtensionPoint,
          ~opts,
          (),
        )

        {
          id,
          version,
          heartbeatInterval,
          eventCollector: eventCollectorOutputs,
          extensionPoints: extensionPointsOutputs->toDict,
          extensions: extensionsOutputs->toDict,
          aggregates: aggregatesOutputs,
          readModels: readModelsOutputs,
          tasks: tasksOutputs.contents->toDict,
          resolvers,
          heartbeat: heartbeat->Component.extractOutputs,
          serviceNameToExtensionPointsMapping,
          outgoingServiceNameToExtensionsMapping,
          incomingServiceNameToExtensionsMapping,
          readModelNamesForSourceName,
        }
      })
    }
    self->setOutputs(
      makeOutputs(
        ~id=pureOutputs->Pulumi.Output.apply(outputs => outputs.id),
        ~version=pureOutputs->Pulumi.Output.apply(outputs => outputs.version),
        ~heartbeatInterval=pureOutputs->Pulumi.Output.apply(outputs => outputs.heartbeatInterval),
        ~eventCollector=pureOutputs->Pulumi.Output.apply(outputs => outputs.eventCollector),
        ~extensionPoints=pureOutputs->Pulumi.Output.apply(outputs => outputs.extensionPoints),
        ~extensions=pureOutputs->Pulumi.Output.apply(outputs => outputs.extensions),
        ~aggregates=pureOutputs->Pulumi.Output.apply(outputs => outputs.aggregates),
        ~readModels=pureOutputs->Pulumi.Output.apply(outputs => outputs.readModels),
        ~tasks=pureOutputs->Pulumi.Output.apply(outputs => outputs.tasks),
        ~resolvers=pureOutputs->Pulumi.Output.apply(outputs => outputs.resolvers),
        ~heartbeat=pureOutputs->Pulumi.Output.apply(outputs => outputs.heartbeat),
        ~serviceNameToExtensionPointsMapping=pureOutputs->Pulumi.Output.apply(outputs =>
          outputs.serviceNameToExtensionPointsMapping
        ),
        ~outgoingServiceNameToExtensionsMapping=pureOutputs->Pulumi.Output.apply(outputs =>
          outputs.outgoingServiceNameToExtensionsMapping
        ),
        ~incomingServiceNameToExtensionsMapping=pureOutputs->Pulumi.Output.apply(outputs =>
          outputs.incomingServiceNameToExtensionsMapping
        ),
        ~readModelNamesForSourceName=pureOutputs->Pulumi.Output.apply(outputs =>
          outputs.readModelNamesForSourceName
        ),
      ),
    )
  }

  let make = (
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
      ~construct=construct(
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
    )
}
