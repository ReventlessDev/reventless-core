let componentType = ComponentType.Plugin;

type taskMakers = array(Task.maker);
type serviceMakers = array(Service.maker);
type eventMapperMakers = array(EventMapper.maker);

type outputs = {
  .
  "services": array(Service.t),
  "tasks": array(Task.t),
  "eventMappers": array(EventMapper.t),
  "resolvers": Pulumi.Output.t(array(Adapter.resource)),
};
type t = outputs;

module type T = {
  let make:
    (
      ~name: string,
      ~serviceMakers: serviceMakers,
      ~taskMakers: taskMakers,
      ~eventMapperMakers: eventMapperMakers,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    t;
};

module Make =
       (Config: Config.T, EventCollectorConnector: EventCollector.Connector)
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
      ~services: array(Service.t),
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
        ~serviceMakers: serviceMakers,
        ~taskMakers: taskMakers,
        ~eventMapperMakers: eventMapperMakers,
        self,
        _,
      ) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );
    let services =
      serviceMakers->Belt.Array.map(serviceMaker =>
        serviceMaker(Some(opts))
      );

    let queryCommandTopic =
      InterstackResourceQueryRuntime.commandTopicConnectorOfAllServicesExn(
        services->Interstack.mergeServices,
      );

    let queryEventTopic =
      InterstackResourceQueryDeploytime.eventTopicPublisherOfAllServicesExn(
        services,
      );

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
                   ((val policies), EventCollectorConnector);
               module EventMapper =
                 EventMapper.Make((val mappings), EventCollector);
               Some(EventMapper.make);
             | (Some((mappings: (module EventMapping.Mappings))), None) =>
               module EventCollector =
                 EventCollector.Make
                   // TODO: general EventCollector
                   (EventCollector.NoPolicies, EventCollectorConnector);
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

    makeOutputs(
      ~services,
      ~tasks=tasks^,
      ~eventMappers=eventMappers^,
      ~resolvers,
    )
    |> self->setOutputs;
  };

  let make:
    (
      ~name: string,
      ~serviceMakers: serviceMakers,
      ~taskMakers: taskMakers,
      ~eventMapperMakers: eventMapperMakers,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    t =
    (~name, ~serviceMakers, ~taskMakers, ~eventMapperMakers, ~opts=?, _unit) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=name->ComponentType.name(componentType),
        ~construct=construct(~serviceMakers, ~taskMakers, ~eventMapperMakers),
        ~opts,
      );
};
