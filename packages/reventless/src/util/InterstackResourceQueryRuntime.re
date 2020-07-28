include ResourceQueryRuntime;
open InterstackResourceQuery;

let commandTopicConnectorOfAllServicesExn = (services, serviceName) =>
  services
  ->Pulumi.Output.get
  ->commandTopicConnectorOfAllServices(serviceName)
  ->unwrapResource("CommandTopic", serviceName);

let queryDbStorageOfAllServicesExn = (services, serviceName) =>
  services
  ->Pulumi.Output.get
  ->queryDbStorageOfAllServices(serviceName)
  ->unwrapResource("queryDbStorage", serviceName);

let eventCollectorConnectorOfAllEventMappersExn =
    (eventMappersRef, eventMapperName) =>
  eventMappersRef
  ->Pulumi.Output.get
  ->eventCollectorConnectorOfAllEventMappers(eventMapperName)
  ->unwrapResource("EventCollector", eventMapperName);

let bucketNameOfAllTasks: (array(Task.t), string) => option(string) =
  (tasks, taskName) => {
    tasks
    ->find(taskName)
    ->Belt.Option.flatMap(task => task##bucket)
    ->Belt.Option.map(bucket => bucket##bucket->OutputFailsafeRuntime.get);
  };

let bucketNameOfTaskExn = (tasksRef, taskName) =>
  tasksRef
  ->Pulumi.Output.get
  ->bucketNameOfAllTasks(taskName)
  ->unwrapResource("Bucket", taskName);
