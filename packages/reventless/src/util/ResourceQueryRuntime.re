let find: (array('a), string) => option('a) =
  (resources, name) =>
    resources->Belt.Array.reduce(None, (result, resource) =>
      resource##name == name ? Some(resource) : result
    );

let commandTopicConnectorOfAllServices:
  (array(Service.outputs), string) => option(Adapter.resource) =
  (services, serviceName) =>
    services
    ->find(serviceName)
    ->Belt.Option.map(service => service##aggregate##commandTopic##connector);

// NOTE: only works with 1 ReadModel per Service !
let queryDbStorageOfAllServices:
  (array(Service.outputs), string) => option(Adapter.resource) =
  (services, serviceName) =>
    services
    ->find(serviceName)
    ->Belt.Option.map(service => service##readModel##queryDb##storage);

let eventCollectorConnectorOfAllEventMappers:
  (array(EventMapper.outputs), string) => option(Adapter.resource) =
  (eventMappers, eventMapperName) =>
    eventMappers
    ->find(eventMapperName)
    ->Belt.Option.map(eventMapper => eventMapper##eventCollector##connector);

let bucketNameOfAllTasks: (array(Task.outputs), string) => option(string) =
  (tasks, taskName) => {
    tasks
    ->find(taskName)
    ->Belt.Option.flatMap(task => task##bucket)
    ->Belt.Option.map(bucket => bucket##bucket->Pulumi.Output.get);
  };

let eventCollectorConnectorOfAllEventMappersExn =
    (eventMappersRef, eventMapperName) =>
  eventCollectorConnectorOfAllEventMappers(eventMappersRef^, eventMapperName)
  ->ResourceQuery.unwrapResource("EventCollector", eventMapperName);

let bucketNameOfTaskExn = (tasksRef, taskName) =>
  bucketNameOfAllTasks(tasksRef^, taskName)
  ->ResourceQuery.unwrapResource("Bucket", taskName);
