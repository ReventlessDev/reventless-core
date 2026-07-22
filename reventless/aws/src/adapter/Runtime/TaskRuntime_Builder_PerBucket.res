module RuntimeEnvironment = RuntimeEnvironment.Lambda
module TaskBucket = TaskBucket.S3

type context = PulumiAws.Lambda.context
type callbackEvent = TaskBucket.callbackEvent
type runtimeParts = Util.Lambda.runtimeParts

let forBucketCallback = (
  ~handler as _,
  ~connect,
  ~memorySize=4096,
  ~timeout=600,
  ~name,
  ~callbackModulePath,
  ~publishToAggregatesQueueUrls,
  ~schedulerConfig: option<ReventlessCore.TaskRuntime_Builder.schedulerConfig>,
  task: ReventlessCore.Task.component,
) => {
  let resource = task->ReventlessCore.Component.toPulumiResource
  // `name` is the PascalCase bucket stem (empty for the default bucket); the
  // SideEffectHandler Lambda for this task bucket reads `<Task><Bucket>SideEffectHandler`.
  let fullName = resource.name->Option.getOr("UnnamedTask") ++ name ++ "SideEffectHandler"

  let envVars: dict<Pulumi.Input.t<string>> = Dict.make()

  // Build publishToAggregates env var mapping.
  // Task Lambdas use PUBLISH_<Agg>_QUEUE_URL; Extension Point Lambdas use PTA_<Agg>_QUEUE_URL.
  // The prefix difference is intentional — they are distinct feature areas with separate builders.
  // Each entry point reads whichever prefix its own builder writes, so the two sets never clash.
  let publishToAggregatesEnvVars: dict<string> = Dict.make()
  publishToAggregatesQueueUrls->Dict.forEachWithKey((queueUrlOutput, aggName) => {
    let envVar = `PUBLISH_${aggName}_QUEUE_URL`
    envVars->Dict.set(envVar, queueUrlOutput->Pulumi.Output.asInput)
    publishToAggregatesEnvVars->Dict.set(aggName, envVar)
  })

  // Build HANDLER_CONFIG JSON
  let callbackModule =
    callbackModulePath->JSON.stringifyAny->Option.getOr(`""`)
  let publishToAggregatesJson =
    publishToAggregatesEnvVars
    ->Dict.toArray
    ->Array.map(((aggName, envVar)) =>
      `${aggName->JSON.stringifyAny->Option.getOr(`""`)}: ${envVar->JSON.stringifyAny->Option.getOr(`""`)}`
    )
    ->Array.join(",")

  // Encode scheduler config (CloudWatch Events role + side-effect target queue)
  // into HANDLER_CONFIG so the bundled Lambda can call PutRule/PutTargets at
  // runtime. None for tasks without a side-effect handler.
  let handlerConfigJson = switch schedulerConfig {
  | None =>
    `{"callbackModule":${callbackModule},"publishToAggregates":{${publishToAggregatesJson}}}`
    ->Pulumi.Output.make
  | Some({schedulerRoleUrn, targetUrn, targetName}) =>
    envVars->Dict.set("SCHEDULER_ROLE_ARN", schedulerRoleUrn->Pulumi.Output.asInput)
    envVars->Dict.set("SCHEDULER_TARGET_ARN", targetUrn->Pulumi.Output.asInput)
    envVars->Dict.set("SCHEDULER_TARGET_NAME", targetName->Pulumi.Output.asInput)
    `{"callbackModule":${callbackModule},"publishToAggregates":{${publishToAggregatesJson}},"scheduler":{"roleArnEnv":"SCHEDULER_ROLE_ARN","targetArnEnv":"SCHEDULER_TARGET_ARN","targetNameEnv":"SCHEDULER_TARGET_NAME"}}`
    ->Pulumi.Output.make
  }
  envVars->Dict.set("HANDLER_CONFIG", handlerConfigJson->Pulumi.Output.asInput)

  // Build code asset
  let packageDirs: dict<string> = Dict.make()
  let pkg = Util_Bundle.extractPackageName(callbackModulePath)
  packageDirs->Dict.set(pkg, Util_Bundle.resolvePackageRoot(pkg))

  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/TaskBucketEntryPoint.mjs",
    ~packageDirs,
  )

  let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
    ~name=fullName,
    ~unitKind=ReventlessCore.Monitoring.Task,
    ~componentKind=ReventlessCore.ComponentType.Task,
    ~code,
    ~sourceCodeHash,
    ~envVars,
    ~memorySize,
    ~timeout,
    ~opts={Pulumi.ComponentResource.parent: resource},
  )

  // Grant the Task Lambda role permission to manage CloudWatch Events rules
  // and pass the scheduler role to events. Only needed when a schedulerConfig
  // is present (Tasks with side effects).
  switch schedulerConfig {
  | None => ()
  | Some({schedulerRoleUrn}) =>
    let lambdaRole = runtime.parts.lambdaRole
    let _ = schedulerRoleUrn->Pulumi.Output.apply(arn => {
      let _ = PulumiAws.IAM.RolePolicy.make(
        ~name=`${fullName}SchedulerPolicy`,
        ~args={
          policy: PulumiAws.PolicyDocument.make(
            ~id=`${fullName}SchedulerPolicy`,
            ~statements=[
              {
                sid: "AllowCloudWatchEvents",
                effect: Allow,
                actions: Action("events:*"),
                resources: AllResources,
              },
              {
                sid: "AllowPassSchedulerRole",
                effect: Allow,
                actions: Action("iam:PassRole"),
                resources: Resource(arn),
              },
            ],
          )
          ->PulumiAws.PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
      )
    })
  }

  connect(~runtime)
}

let finish = () => ()
