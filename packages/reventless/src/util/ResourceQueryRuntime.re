let find: (array('a), string) => option('a) =
  (resources, name) =>
    resources->Belt.Array.reduce(None, (result, resource) =>
      resource##name == name ? Some(resource) : result
    );

let serviceOfContext: (Context.t, string) => option(Service.t) =
  (context, serviceName) => context##services->find(serviceName);

let serviceOfContexts:
  (array(Context.t), string, string) => option(Service.t) =
  (contexts, contextName, serviceName) =>
    contexts
    /* NOTE: don't use `Context.componentType` since this results in requiring
               Context.bs.js -> Component.js -> @pulumi/pulumi and will fail during runtime
       */
    ->find(contextName->ComponentType.name(ComponentType.Context))
    ->Belt.Option.flatMap(context => context->serviceOfContext(serviceName));

let serviceOfAllContexts: (array(Context.t), string) => option(Service.t) =
  (contexts, serviceName) =>
    contexts
    ->Belt.Array.map(context => context->serviceOfContext(serviceName))
    ->Belt.Array.reduce(None, (result, resource) =>
        switch (result, resource) {
        | (_, Some(_) as r) => r
        | (r, None) => r
        }
      );

let aggregateOfAllContexts = (contexts, serviceName) =>
  contexts
  ->serviceOfAllContexts(serviceName)
  ->Belt.Option.map(service => service##aggregate);

let commandTopicConnectorOfAllContexts:
  (array(Context.t), string) => option(Adapter.resource) =
  (contexts, serviceName) =>
    contexts
    ->aggregateOfAllContexts(serviceName)
    ->Belt.Option.map(aggregate => aggregate##commandTopic##connector);

let commandTopicConnectorOfAllContextsExn = (contexts, serviceName) =>
  commandTopicConnectorOfAllContexts(contexts, serviceName)
  ->ResourceQuery.unwrapResource("CommandTopic", serviceName);

// NOTE: only works with 1 ReadModel per Service !
let queryDbStorageOfAllContexts:
  (array(Context.t), string) => option(Adapter.resource) =
  (contexts, serviceName) =>
    contexts
    ->serviceOfAllContexts(serviceName)
    ->Belt.Option.map(service => service##readModel##queryDb##storage);

let eventCollectorConnectorOfAllEventMappers:
  (array(EventMapper.t), string) => option(Adapter.resource) =
  (eventMappers, eventMapperName) =>
    eventMappers
    ->find(eventMapperName)
    ->Belt.Option.map(eventMapper => eventMapper##eventCollector##connector);

let bucketNameOfAllTasks: (array(Task.t), string) => option(string) =
  (tasks, taskName) => {
    tasks
    ->find(taskName)
    ->Belt.Option.flatMap(task => task##bucket)
    ->Belt.Option.map(bucket => bucket##bucket->Pulumi.Output.get);
  };

let queryDbStorageOfAllContextsExn = (contexts, serviceName) =>
  queryDbStorageOfAllContexts(contexts, serviceName)
  ->ResourceQuery.unwrapResource("queryDbStorage", serviceName);

let eventCollectorConnectorOfAllEventMappersExn =
    (eventMappersRef, eventMapperName) =>
  eventCollectorConnectorOfAllEventMappers(eventMappersRef^, eventMapperName)
  ->ResourceQuery.unwrapResource("EventCollector", eventMapperName);

let bucketNameOfTaskExn = (tasksRef, taskName) =>
  bucketNameOfAllTasks(tasksRef^, taskName)
  ->ResourceQuery.unwrapResource("Bucket", taskName);
