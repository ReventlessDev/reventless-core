let log = Logger.fromEnv()

// PascalCase a (possibly kebab/snake-case) bucket id for use as a resource-name
// segment: "product-imports" -> "ProductImports". The raw id stays the runtime
// lookup key; only the emitted resource name is sanitized.
let pascalCase = s =>
  s
  ->String.split("-")
  ->Array.flatMap(p => p->String.split("_"))
  ->Array.filter(p => p->String.length > 0)
  ->Array.map(p =>
    p->String.slice(~start=0, ~end=1)->String.toUpperCase ++
      p->String.slice(~start=1, ~end=p->String.length)
  )
  ->Array.join("")

// Split words out of a PascalCase/camelCase run so kebab-casing keeps the word
// boundaries. Two passes: `aB` splits an ordinary hump, `ABc` splits the tail of
// an acronym off the word that follows it ("HTTPServer" -> "HTTP-Server").
let humpBoundary = %re("/([a-z0-9])([A-Z])/g")
let acronymBoundary = %re("/([A-Z]+)([A-Z][a-z])/g")

// Kebab-case an identifier for use in an S3 bucket name: "ImportProducts" and
// "product-imports" both reduce to "import-products".
//
// S3 lowercases bucket names, so a PascalCase segment collapses into an
// unreadable run-on ("importproductsproductimportsbucket"). Kebab survives the
// lowercasing with its word boundaries intact, which is why the framework's
// declared-store buckets (`Util_StoreLayout.bucketNameFor`) already use it.
let kebabCase = s =>
  s
  ->String.replaceRegExp(acronymBoundary, "$1-$2")
  ->String.replaceRegExp(humpBoundary, "$1-$2")
  ->String.split("-")
  ->Array.flatMap(p => p->String.split("_"))
  ->Array.filter(p => p->String.length > 0)
  ->Array.map(String.toLowerCase)
  ->Array.join("-")

// S3 caps a bucket name at 63 characters and Pulumi appends `-` plus a 7-char
// uniqueness suffix, so the composed name has 55 to work with.
let maxBucketNameLength = 55

/**
The Pulumi resource name for a task's bucket: `{plugin}-{task}` for a task's
default bucket, `{plugin}-{task}-{bucketId}` when the declaration names one.

`plugin` is the ambient plugin under construction, absent for a task built
outside any plugin. No `Bucket` suffix — `aws:s3/bucket` and the
`reventless:role=Bucket` tag both already say what it is.

Composed rather than sanitised, so a name too long for S3 is the caller's to fix:
truncating here would silently manufacture a collision between two long names
that share a prefix.
*/
let bucketResourceName = (
  ~plugin: option<string>,
  ~task: string,
  ~bucketId: option<string>,
): string => {
  let name =
    [plugin, Some(task), bucketId]
    ->Array.filterMap(segment => segment)
    ->Array.map(kebabCase)
    ->Array.filter(segment => segment != "")
    ->Array.join("-")
  if name->String.length > maxBucketNameLength {
    JsError.throwWithMessage(
      `Task bucket name "${name}" is ${name
        ->String.length
        ->Int.toString} characters; S3 allows ${maxBucketNameLength->Int.toString} once Pulumi's ` ++
      `uniqueness suffix is added. Shorten the task name` ++
      switch bucketId {
      | Some(id) => ` or the bucket id "${id}".`
      | None => "."
      },
    )
  }
  name
}

module Make = (
  Spec: Task.Spec,
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel,
  TaskRuntimeBuilder: TaskRuntime_Builder.T with type runtimeParts = RuntimeEnvironment.parts,
  TaskBucket: Task_Adapter.Bucket
    with type runtimeParts = RuntimeEnvironment.parts
    and type callbackEvent = TaskRuntimeBuilder.callbackEvent
    and type runtimeParts = RuntimeEnvironment.parts
    and type context = TaskRuntimeBuilder.context,
  SpecificSideEffectHandler: SideEffectHandler.T,
  Defaults: ReventlessInfra.RuntimeDefaults.T,
): Task.T => {
  module Spec = Spec
  type component = Task.component
  // type handler = Runtime.eventHandler<
  //   TaskRuntimeBuilder.callbackEvent,
  //   TaskRuntimeBuilder.context,
  //   array<Task.taskAction>,
  // >

  let construct = (
    ~queryBucketName,
    ~scheduler,
    ~schedulerRoleUrn,
    ~publishToAggregates,
    ~queryEngine,
    ~resourceNaming: ReventlessInfra.ResourceNaming.operations,
    ~allAggregates,
    ~runtime,
    self,
    taskName,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    // Task bucket callbacks default to the platform-supplied task-pod floor (a
    // large envelope for bulk import/export work); a plugin.json `runtime`
    // override raises memory above it and replaces timeout.
    let memorySize = ReventlessInfra.RuntimeHints.resolveMemory(runtime, ~default=Defaults.memorySize)
    let timeout = ReventlessInfra.RuntimeHints.resolveTimeout(runtime, ~default=Defaults.timeout)
    let allCommandTopics = allAggregates->Aggregate.allCommandTopics

    // Each adapter chooses what string the Task runtime should treat as the
    // publish address for a target aggregate. By convention we expose the
    // first command-topic resource's `id` — bundled adapters interpret it as
    // their channel address; adapters that don't need it (e.g. in-memory)
    // ignore the dict in their TaskRuntime_Builder.
    let publishToAggregatesQueueUrls =
      allAggregates->Dict.mapValues(agg =>
        agg.commandTopic->Pulumi.Output.flatMap(ct =>
          switch ct.resources->Array.get(0) {
          | Some(r) => r.id
          | None => Pulumi.Output.make("")
          }
        )
      )

    let publishCommands: Task.publishCommands = (aggregateName, cmdJsons) => {
      (publishToAggregates->Dict.get(aggregateName)->Option.getOrThrow)(cmdJsons)
    }

    let config = Spec.setup(queryEngine, queryBucketName, opts)

    let sideEffectHandler =
      config.sideEffects->Option.map(sideEffects =>
        SpecificSideEffectHandler.make(
          ~name=taskName,
          ~sideEffects,
          ~allEventTopics=allAggregates->Aggregate.allEventTopics,
          ~allCommandTopics,
          ~queryEngine,
          ~scheduler,
          ~resourceNaming,
          ~opts,
        )
      )

    // The handler's runtime is provisioned by `SpecificSideEffectHandler.finish()`,
    // not by `make` — see `SideEffectHandler.T.finish`. Register it with the gate that
    // says this handler has reached its runtime builder: `operations` is set at the end
    // of the builder's construct, after `forEventCollector` has run.
    sideEffectHandler->Option.forEach(handler =>
      Builder_Helpers.registerTaskSideEffectHandler(
        ~gate=handler->Component.operations->Pulumi.Output.apply(_ => ()),
        ~finish=SpecificSideEffectHandler.finish,
      )
    )

    let taskActionsHandler = (taskActions, operations: option<SideEffectHandler.operations>) => {
      taskActions
      ->Array.map(async taskAction => {
        switch taskAction {
        | Task.PublishCommands(aggregateName, cmdJsons) =>
          await publishCommands(aggregateName, cmdJsons)
        | CreateSchedule(schedule) =>
          switch operations {
          | Some(operations) => await operations.createSchedule(schedule)
          | None => log.info(~comp="Task", "No SideEffectHandler to create schedule")
          }
        | DeleteSchedule(scheduleId) =>
          switch operations {
          | Some(operations) => await operations.deleteSchedule(scheduleId)
          | None => log.info(~comp="Task", "No SideEffectHandler to delete schedule")
          }
        }
      })
      ->Promise.all
      ->Util.Promise.toUnit
    }

    let createHandler = (sideEffectHandler, callback) => {
      let handler = callback->TaskBucket.makeHandler
      switch sideEffectHandler {
      | Some(sideEffectHandler) =>
        sideEffectHandler
        ->Component.operations
        ->Pulumi.Output.apply(operations =>
          async (event, context) => {
            let taskActions = await handler(event, context)
            await taskActions->taskActionsHandler(Some(operations))
          }
        )
      | None =>
        (
          async (event, context) => {
            let taskActions = await handler(event, context)
            await taskActions->taskActionsHandler(None)
          }
        )->Pulumi.Output.make
      }
    }

    // Build schedulerConfig from the side-effect handler's collector channel
    // — the resource scheduled events fire into — paired with the platform
    // scheduler's invoker URN. Bundled adapters thread these into the
    // deployed handler so it can talk to the underlying scheduler service;
    // adapters without a real scheduler ignore the dict.
    let schedulerConfig: option<TaskRuntime_Builder.schedulerConfig> =
      sideEffectHandler->Option.flatMap(seh => {
        let sehOutputs = seh->Component.outputs
        sehOutputs.eventCollector.resources
        ->Array.get(0)
        ->Option.map(r => {
          TaskRuntime_Builder.schedulerRoleUrn: schedulerRoleUrn,
          targetUrn: r.urn,
          targetName: r.name,
        })
      })

    let bucketNames = config.buckets->Option.map(buckets =>
      buckets
      ->Array.map(bucketSpec => {
        let bucketName = bucketSpec.bucketName->Option.getOr("Bucket")
        // `bucketStem` is the PascalCase segment naming this bucket's Lambda
        // (empty for the default unnamed bucket). `bucketName` above remains the
        // runtime key into `Task.bucketNames`; `name` is the bucket's own
        // resource name, kebab-cased and plugin-qualified because S3 lowercases
        // it — see `bucketResourceName`.
        let bucketStem = bucketSpec.bucketName->Option.mapOr("", pascalCase)
        let name = bucketResourceName(
          ~plugin=ResourceAttribution.current.contents.plugin,
          ~task=taskName,
          ~bucketId=bucketSpec.bucketName,
        )
        let bucket = TaskBucket.make(~name, ~opts)
        let opts = {Pulumi.ComponentResource.parent: bucket.parts->Pulumi.Resource.makeFromJs}

        bucketSpec.callback->Option.forEach(
          callback =>
            self->TaskRuntimeBuilder.forBucketCallback(
              ~handler=sideEffectHandler->createHandler(callback),
              ~connect=TaskBucket.connect(
                ~name,
                ~bucket,
                ~bucketMode=bucketSpec.bucketMode,
                ~commandTopics=allCommandTopics,
                ~opts,
                ...
              ),
              ~memorySize,
              ~timeout,
              ~name=bucketStem,
              ~callbackModulePath=Spec.moduleUrl,
              ~publishToAggregatesQueueUrls,
              ~schedulerConfig,
            ),
        )

        (bucketName, (bucket.resources->Array.getUnsafe(0)).id)
      })
      ->Dict.fromArray
    )

    let sideEffectSources =
      config.sideEffects->Option.map(sideEffect =>
        sideEffect->Array.map((module(SideEffect)) => SideEffect.Source.name)
      )

    self->Component.setOutputs({name: taskName, ?bucketNames, ?sideEffectSources})
  }

  let make = (
    ~queryBucketName,
    ~scheduler,
    ~schedulerRoleUrn,
    ~publishToAggregates,
    ~queryEngine,
    ~resourceNaming,
    ~allAggregates,
    ~runtime=?,
    ~opts,
  ) =>
    Component.make(
      ~componentType=Task.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(
        ~queryBucketName,
        ~scheduler,
        ~schedulerRoleUrn,
        ~publishToAggregates,
        ~queryEngine,
        ~resourceNaming,
        ~allAggregates,
        ~runtime,
        ...
      ),
      ~opts,
    )

  let outputs = Component.outputs
}
