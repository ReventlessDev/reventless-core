//include ResourceQueryDeploytime;

let eventTopicPublisherOfAllContextsExn = (contexts, serviceName) =>
  contexts
  ->Interstack.mergeContexts
  ->Pulumi.Output.apply(contexts =>
      ResourceQueryDeploytime.eventTopicPublisherOfAllContextsExn(
        contexts,
        serviceName,
      )
    );

let queryDbStorageOfAllContextsExn = (contexts, serviceName) =>
  contexts
  ->Interstack.mergeContexts
  ->Pulumi.Output.apply(contexts =>
      ResourceQueryDeploytime.queryDbStorageOfAllContextsExn(
        contexts,
        serviceName,
      )
    );

let allResolversMakers = ResourceQueryDeploytime.allResolversMakers;

let bucketOfAllTasksExn:
  (ref(array(Task.t)), string) =>
  Pulumi.Output.t(PulumiAws.S3.Bucket.bucket) =
  (tasks, taskName) => {
    tasks
    ->Interstack.mergeTasks
    ->Pulumi.Output.apply(tasks =>
        tasks
        ->ResourceQueryDeploytime.find(taskName)
        ->Belt.Option.flatMap(task => task##bucket)
        ->Belt.Option.getExn
      );
  };
