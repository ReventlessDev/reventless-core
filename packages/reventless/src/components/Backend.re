let componentType = ComponentType.Backend;

type contextMakers = array(Context.maker);
type taskMakers = array(Task.maker);
type eventMapperMakers = array(EventMapper.maker);

type outputs = {
  .
  "contexts": array(Context.t),
  "tasks": array(Task.t),
  "eventMappers": array(EventMapper.t),
  "resolvers": Pulumi.Output.t(array(Adapter.resource)),
};
type t = outputs;

module type T = {
  let make:
    (
      ~name: string,
      ~contextMakers: contextMakers,
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
      ~contexts: array(Context.t),
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
        ~contextMakers,
        ~taskMakers: array(Task.maker),
        ~eventMapperMakers,
        self,
        _,
      ) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );
    let contexts =
      contextMakers |> Array.map(contextMaker => contextMaker(Some(opts)));

    let queryCommandTopic =
      InterstackResourceQueryRuntime.commandTopicConnectorOfAllContextsExn(
        contexts->Interstack.mergeContexts,
      );
    let queryEventTopic =
      InterstackResourceQueryDeploytime.eventTopicPublisherOfAllContextsExn(
        contexts,
      );
    let queryQueryDb =
      InterstackResourceQueryRuntime.queryDbStorageOfAllContextsExn(
        contexts->Interstack.mergeContexts,
      );
    let queryQueryDbDeploytime =
      InterstackResourceQueryDeploytime.queryDbStorageOfAllContextsExn(
        contexts,
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
                   (
                     Config,
                     (val mappings),
                     (val policies),
                     EventCollectorConnector,
                   );
               module EventMapper =
                 EventMapper.Make(Config, (val mappings), EventCollector);
               Some(EventMapper.make);
             | (Some((mappings: (module EventMapping.Mappings))), None) =>
               module EventCollector =
                 EventCollector.Make
                   // TODO: general EventCollector
                   (
                     Config,
                     (val mappings),
                     EventCollector.NoPolicies,
                     EventCollectorConnector,
                   );
               module EventMapper =
                 EventMapper.Make(Config, (val mappings), EventCollector);
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
      contexts
      ->InterstackResourceQueryDeploytime.allResolversMakers
      ->Belt.Array.map(resolverMaker => resolverMaker(queryQueryDbDeploytime))
      ->Belt.Array.concatMany;

    makeOutputs(
      ~contexts,
      ~tasks=tasks^,
      ~eventMappers=eventMappers^,
      ~resolvers,
    )
    |> self->setOutputs;
  };

  let make:
    (
      ~name: string,
      ~contextMakers: contextMakers,
      ~taskMakers: taskMakers,
      ~eventMapperMakers: eventMapperMakers,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    t =
    (~name, ~contextMakers, ~taskMakers, ~eventMapperMakers, ~opts=?, _unit) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=name->ComponentType.name(componentType),
        ~construct=construct(~contextMakers, ~taskMakers, ~eventMapperMakers),
        ~opts,
      );
};