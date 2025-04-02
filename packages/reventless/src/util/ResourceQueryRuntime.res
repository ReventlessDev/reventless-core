let bucketNameOfAllTasks: (array<Task.outputs>, string) => option<string> = (tasks, taskName) =>
  tasks
  ->Array.find(task => task.name == taskName)
  ->Option.flatMap(task => task.bucket)
  ->Option.map(bucket => bucket.bucket->Pulumi.Output.get)

let bucketNameOfTaskExn = (tasks, taskName) =>
  bucketNameOfAllTasks(tasks, taskName)->ResourceQuery.unwrapResource("Bucket", taskName)
