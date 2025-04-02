include ResourceQueryRuntime
open InterstackResourceQuery

let bucketNameOfAllTasks: (array<Task.outputs>, string) => option<string> = (tasks, taskName) =>
  tasks
  ->Array.find(task => task.name == taskName)
  ->Option.flatMap(task => task.bucket)
  ->Option.map(bucket => bucket.bucket->OutputFailsafeRuntime.get)

let bucketNameOfTaskExn = (tasks, taskName) =>
  tasks->Pulumi.Output.get->bucketNameOfAllTasks(taskName)->unwrapResource("Bucket", taskName)
