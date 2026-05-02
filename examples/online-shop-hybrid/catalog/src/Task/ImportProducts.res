@@reventless.task

let setup = (
  _queryEngine,
  _queryBucketName,
  _opts,
): Task.config => {
  Task.buckets: [
    {
      bucketName: "product-imports",
      bucketMode: Task.Read,
      callback: (~eventName as _, ~key as _) => []->Promise.resolve,
    },
  ],
}
