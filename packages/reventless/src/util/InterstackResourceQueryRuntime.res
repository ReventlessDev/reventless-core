include ResourceQueryRuntime
open InterstackResourceQuery

let eventCollectorConnectorOfAllEventMappersExn = (eventMappersRef, eventMapperName) =>
  eventMappersRef
  ->Pulumi.Output.get
  ->eventCollectorConnectorOfAllEventMappers(eventMapperName)
  ->unwrapResource("EventCollector", eventMapperName)

let bucketNameOfAllTasks: (array<Task.outputs>, string) => option<string> = (tasks, taskName) =>
  tasks
  ->Belt.Array.getBy(task => task.name == taskName)
  ->Belt.Option.flatMap(task => task.bucket)
  ->Belt.Option.map(bucket => bucket.bucket->OutputFailsafeRuntime.get)

let bucketNameOfTaskExn = (tasks, taskName) =>
  tasks->Pulumi.Output.get->bucketNameOfAllTasks(taskName)->unwrapResource("Bucket", taskName)
