open ReventlessSpec.Adapter

let eventCollectorConnectorOfAllEventMappers: (
  array<EventMapper.outputs>,
  string,
) => option<resource> = (eventMappers, eventMapperName) =>
  eventMappers
  ->Belt.Array.getBy(eventMapper => eventMapper.name == eventMapperName)
  ->Belt.Option.flatMap(eventMapper => {
    let resources = eventMapper.eventCollector.resources
    resources->Belt.Array.length > 0 ? Some(resources->Array.getUnsafe(0)) : None
  })

let bucketNameOfAllTasks: (array<Task.outputs>, string) => option<string> = (tasks, taskName) =>
  tasks
  ->Belt.Array.getBy(task => task.name == taskName)
  ->Belt.Option.flatMap(task => task.bucket)
  ->Belt.Option.map(bucket => bucket.bucket->Pulumi.Output.get)

let eventCollectorConnectorOfAllEventMappersExn = (eventMappersRef, eventMapperName) =>
  eventCollectorConnectorOfAllEventMappers(
    eventMappersRef.contents,
    eventMapperName,
  )->ResourceQuery.unwrapResource("EventCollector", eventMapperName)

let bucketNameOfTaskExn = (tasks, taskName) =>
  bucketNameOfAllTasks(tasks, taskName)->ResourceQuery.unwrapResource("Bucket", taskName)
