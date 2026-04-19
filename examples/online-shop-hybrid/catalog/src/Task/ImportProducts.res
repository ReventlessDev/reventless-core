open Reventless

let name = "ImportProducts"

let setup = (
  _queryEngine: QueryEngine.operations,
  _queryBucketName: ReventlessInfra.Task.queryBucketName,
  _opts: Pulumi.ComponentResource.options,
): Task.config => {
  Task.buckets: [
    {
      bucketName: "product-imports",
      bucketMode: Task.Read,
      callback: (~eventName as _, ~key as _) => []->Promise.resolve,
    },
  ],
}
