let bucketNameOfAllTasks: (
  array<Task.outputs>,
  ~taskName: string,
  ~bucketName: string,
) => option<string> = (tasks, ~taskName, ~bucketName) =>
  tasks
  ->Array.find(task => task.name == taskName)
  ->Option.flatMap(task => task.buckets->Option.flatMap(buckets => buckets->Dict.get(bucketName)))
  ->Option.map(bucket => bucket->Pulumi.Output.get)

let bucketNameOfTaskExn = (tasks, ~taskName, ~bucketName) =>
  bucketNameOfAllTasks(tasks, ~taskName, ~bucketName)->ResourceQuery.unwrapResource(
    "Bucket",
    taskName,
  )
