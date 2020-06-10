include ResourceQueryRuntime;
open InterstackResourceQuery;

let commandTopicConnectorOfAllContextsExn = (contexts, serviceName) =>
  contexts
  ->Pulumi.Output.get
  ->commandTopicConnectorOfAllContexts(serviceName)
  ->unwrapResource("CommandTopic", serviceName);

let queryDbStorageOfAllContextsExn = (contexts, serviceName) =>
  contexts
  ->Pulumi.Output.get
  ->queryDbStorageOfAllContexts(serviceName)
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
