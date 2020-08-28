/* TODO: EXTENSION
 *    - inspect events from event-collector:
 *      x if service in event.meta equals one of the extension's extensionPoint-names, then call the appropriate Extension.mapIncomingEvent
 *      x if the service in event.meta equals on of the Plugin's (Context) Aggregates, then call Extension.mapOutgoingEvent on all Extensions
 *      x else raise an error
 *      x map all events from the Plugin-EventCollector which came from the context itself to all ExtensionPoint.mapOutgoingEvents
 *
 *    - if the eventHandler in ExtensionPoint & Extension would return another type than Js.Promise.t(unit)
 *        they could signal if they actually handled the event and if there have been errors
 */

/* TODO: HEARTBEAT + HEALTH-CHECK
 *    - create a Lambda calling a user provided (Plugin.make function argument) health-check function
 *      - the dev provided function should be of type: unit => result(string, string)
 *      - the Plugin.make function argument should be optional
 *    - create a Cloud Event Rule to call the health-check-function in a specified intervall (Plugin.make function argument)
 */

let componentType = ComponentType.Plugin;

type outputs = {
  .
  "eventCollector": EventCollector.t,
  "extensionPoints": Js.Dict.t(ExtensionPoint.t),
  "extensions": Js.Dict.t(Extension.t),
  "services": Js.Dict.t(Service.t),
  "tasks": array(Task.t),
  "eventMappers": array(EventMapper.t),
  "resolvers": Pulumi.Output.t(array(Adapter.resource)),
};
type t = outputs;

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
    ~opts: Pulumi.ComponentResource.Options.t=?,
    unit
  ) =>
  t;

module type T = {let make: maker;};

module Make =
       (Config: Config.T, EventCollectorAdapter: EventCollector.Connector)
       : T => {
  type constructed;
  type construct = (t, string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    t =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~eventCollector: EventCollector.t,
      ~extensionPoints: Js.Dict.t(ExtensionPoint.t),
      ~extensions: Js.Dict.t(Extension.t),
      ~services: Js.Dict.t(Service.t),
      ~tasks: array(Task.t),
      ~eventMappers: array(EventMapper.t),
      ~resolvers: array(Adapter.resource)
    ) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
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
        self,
        name,
      ) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let coreStack =
      Pulumi.Config.make(None)
      ->Pulumi.Config.get("core")
      ->Belt.Option.getExn
      ->Pulumi.StackReference.make;

    let services =
      serviceMakers->Belt.Array.map(serviceMaker =>
        serviceMaker(Some(opts))
      );
    let servicesMap =
      services
      ->Belt.Array.map(service => (service##name, service))
      ->Js.Dict.fromArray;

    let queryCommandTopic =
      InterstackResourceQueryRuntime.commandTopicConnectorOfAllServicesExn(
        services->Interstack.mergeServices,
      );

    let queryExtensionPointCommandTopic = name =>
      Some("")->Js.Promise.resolve; // TODO

    let dictGetExn = (dict, key) =>
      dict->Js.Dict.get(key)->Belt.Option.getExn;

    let (-#) = dictGetExn;

    let queryEventTopic = name =>
      if (name == PluginExtensionPointSpec.name) {
        coreStack
        ->Pulumi.StackReference.getOutput("extensionPoints")
        ->Belt.Option.getExn
        ->Pulumi.Output.apply(extensionPoints =>
            extensionPoints
            -# PluginExtensionPointSpec.name
            -# "eventTopic"
            -# "publisher"
          );
      } else {
        InterstackResourceQueryDeploytime.eventTopicPublisherOfAllServicesExn(
          services,
          name,
        );
      };

    let extensionPoints =
      extensionPointMakers->Belt.Array.map(extensionPointMaker =>
        extensionPointMaker(~queryCommandTopic, ~opts=Some(opts), ())
      );
    let extensionPointsMap =
      extensionPoints
      ->Belt.Array.map(extensionPoint =>
          (extensionPoint##name, extensionPoint)
        )
      ->Js.Dict.fromArray;

    let otherExtensions =
      extensionMakers->Belt.Array.map(extensionMaker =>
        extensionMaker(
          ~queryCommandTopic,
          ~queryExtensionPointCommandTopic,
          ~opts=Some(opts),
          (),
        )
      );

    let eventCollectorId: ref(Pulumi.Output.t(string)) =
      ref("NOT-SET"->Pulumi.Output.make);

    let callHandler =
      fun
      | PluginExtensionPointSpec.ConnectPlugin(pluginSpec) => {
          /* TODO: actually connect given eventTopic to this Plugin.eventCollector*/

          // ExtensionPoint.EventTopic ----> Plugin.EventCollector

          // for every ExtensionPoint of the connected Plugin which has a realted Extension in this Plugin -> connect
          let connectToExtensionPoints =
            pluginSpec.extensionPoints
            ->Belt.Array.map(extensionPoint =>
                otherExtensions
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
            (_id, event, _meta) =>
              switch (event) {
              | PluginExtensionPointSpec.UnknownPluginDetected =>
                let extensionPointsConfig =
                  extensionPoints->Belt.Array.map(extensionPoint =>
                    {
                      PluginSpec.name: extensionPoint##name,
                      commandTopic:
                        extensionPoint##commandTopic##connector##id
                        ->Pulumi.Output.get,
                      eventTopic:
                        extensionPoint##eventTopic##publisher##id
                        ->Pulumi.Output.get,
                    }
                  );
                let extensionsConfig =
                  otherExtensions->Belt.Array.map(extension =>
                    {
                      PluginSpec.name: extension##name,
                      eventCollector: (eventCollectorId^)->Pulumi.Output.get,
                    }
                  );
                [|
                  PublishExtensionPointCommand(
                    {j|$name-$version|j},
                    PluginExtensionPointSpec.ConnectPlugin({
                      PluginSpec.name,
                      version,
                      extensionPoints: extensionPointsConfig,
                      extensions: extensionsConfig,
                    }),
                  ),
                |];
              | PluginConnected(pluginSpec) => [|
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
        ~queryExtensionPointCommandTopic,
        ~opts=Some(opts),
        (),
      );

    let extensions = otherExtensions->Belt.Array.concat([|pluginExtension|]);
    let extensionsMap =
      extensions
      ->Belt.Array.map(extension => (extension##name, extension))
      ->Js.Dict.fromArray;

    let queryQueryDb =
      InterstackResourceQueryRuntime.queryDbStorageOfAllServicesExn(
        services->Interstack.mergeServices,
      );

    let queryQueryDbDeploytime =
      InterstackResourceQueryDeploytime.queryDbStorageOfAllServicesExn(
        services,
      );

    let eventMappers = ref([||]);
    let queryEventCollector =
      InterstackResourceQueryRuntime.eventCollectorConnectorOfAllEventMappersExn(
        eventMappers->Interstack.mergeEventMappers,
      );

    let tasks = ref([||]);
    let queryBucketName =
      InterstackResourceQueryRuntime.bucketNameOfTaskExn(
        tasks->Interstack.mergeTasks,
      );

    let tasksWithEventMappers =
      taskMakers
      |> Array.map(taskMaker =>
           taskMaker(
             ~queryCommandTopic,
             ~queryQueryDb,
             ~queryEventCollector,
             ~queryBucketName,
             ~scheduler=Config.scheduler,
             ~opts=Some(opts),
           )
         )
      |> Array.map(task => {
           let eventMapperMaker =
             switch (task##mappings, task##policies) {
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
           (task, eventMapperMaker);
         })
      |> Belt.Array.unzip;

    tasks := tasksWithEventMappers->fst;

    let taskEventMapperMakers =
      tasksWithEventMappers->snd->Belt.Array.keep(Belt.Option.isSome)
      |> Array.map(Belt.Option.getExn);

    eventMappers :=
      eventMapperMakers->Belt.Array.map((eventMapperMaker: EventMapper.maker) =>
        eventMapperMaker(
          ~queryCommandTopic,
          ~queryEventTopic,
          ~memorySize=128,
          ~opts=Some(opts),
          (),
        )
      )
      |> Belt.Array.concat(
           taskEventMapperMakers
           |> Array.map((eventMapperMaker: EventMapper.maker) =>
                eventMapperMaker(
                  ~queryCommandTopic,
                  ~queryEventTopic,
                  ~memorySize=1024,
                  ~opts=Some(opts),
                  (),
                )
              ),
         );

    let resolvers =
      services
      ->InterstackResourceQueryDeploytime.allResolversMakers
      ->Belt.Array.map(resolverMaker => resolverMaker(queryQueryDbDeploytime))
      ->Belt.Array.concatMany;

    module Set = Belt.Set.String;

    let extensionPointAggregateNames =
      extensionPoints->Belt.Array.map(extensionPoint =>
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
      serviceNameToEx(extensionPoints, ex => ex##aggregateNames);
    let outgoingServiceNameToExtensionsMapping =
      serviceNameToEx(extensions, ex => ex##aggregateNames);
    let incomingServiceNameToExtensionsMapping =
      serviceNameToEx(extensions, ex => [|ex##name|]);

    let extensionAggregateNames =
      extensions->Belt.Array.map(extension =>
        extension##aggregateNames->Set.fromArray
      );

    let aggregateNames: array(string) =
      extensionPointAggregateNames
      ->Belt.Array.concat(extensionAggregateNames)
      ->Belt.Array.reduce(Set.empty, Set.union)
      ->Belt.Set.String.toArray
      ->Belt.Array.concat([|PluginExtensionPointSpec.name|]);

    let handleEvent = (event'Json, dict, getEventHandler) =>
      event'Json
      ->Message.serviceNameOfMsg
      ->Belt.Option.flatMap(serviceName => dict->Js.Dict.get(serviceName))
      ->Belt.Option.mapWithDefault(Js.Promise.resolve(), exs =>
          exs
          ->Belt.Array.map(ex => (getEventHandler(ex))(. event'Json))
          ->Js.Promise.all
          ->Js.Promise.then_(_ => Js.Promise.resolve(), _)
        );

    let getExtensionPointEventHandler = extensionPoint =>
      extensionPoint##eventHandler;
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
      ->Belt.Option.getWithDefault(Js.log2("Unhandled Event:", event'Json));

    let eventHandler =
      (. event'Json) => {
        detectUnhandledEvent(event'Json);
        (
          handleEvent(
            event'Json,
            serviceNameToExtensionPointsMapping,
            getExtensionPointEventHandler,
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
        ~name="Core",
        ~aggregateNames,
        ~eventHandler,
        ~queryEventTopic,
        ~opts=Some(opts),
        (),
      );
    eventCollectorId :=  eventCollector##connector##id;

    makeOutputs(
      ~eventCollector,
      ~extensionPoints=extensionPointsMap,
      ~extensions=extensionsMap,
      ~services=servicesMap,
      ~tasks=tasks^,
      ~eventMappers=eventMappers^,
      ~resolvers,
    )
    |> self->setOutputs;
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
      ~opts=?,
      _unit,
    ) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=name->ComponentType.name(componentType),
        ~construct=
          construct(
            ~version,
            ~timeout,
            ~extensionPointMakers,
            ~extensionMakers,
            ~serviceMakers,
            ~taskMakers,
            ~eventMapperMakers,
          ),
        ~opts,
      );
};
