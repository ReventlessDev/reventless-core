@@reventless.task

let setup = (
  _queryEngine,
  _queryBucketName,
  _opts,
): Task.config => {
  Task.buckets: [
    {
      bucketMode: Task.Read,
      callback: (~eventName as _, ~key as _) => []->Promise.resolve,
    },
  ],
}
