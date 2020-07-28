//include ResourceQueryDeploytime;

let eventTopicPublisherOfAllServicesExn = (services, serviceName) =>
  services
  ->Interstack.mergeServices
  ->Pulumi.Output.apply(services =>
      ResourceQueryDeploytime.eventTopicPublisherOfAllServicesExn(
        services,
        serviceName,
      )
    );

let queryDbStorageOfAllServicesExn = (services, serviceName) =>
  services
  ->Interstack.mergeServices
  ->Pulumi.Output.apply(services =>
      ResourceQueryDeploytime.queryDbStorageOfAllServicesExn(
        services,
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
