// Compiled entry point for Task bucket Lambda handlers.
// Replaces TaskHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
//
// At cold start:
//   1. Reads HANDLER_CONFIG from env vars
//   2. Dynamically imports user callback module from /var/task/node_modules/
//   3. Wires TaskBucket_S3_Runtime.handleBucketEvent(callback)
//   4. Dispatches task actions (PublishCommands → SQS)

// === Dynamic import ===
let dynamicImport: string => promise<'a> = %raw(`(specifier) => import('/var/task/node_modules/' + specifier)`)

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Config types ===

type handlerConfig = {
  callbackModule: string,
  publishToAggregates: dict<string>,
}

type config = handlerConfig

// === Build-verified imports ===

@module("@reventlessdev/reventless-aws/src/adapter/Task/TaskBucket_S3_Runtime.res.mjs")
external handleBucketEvent: 'a => 'b = "handleBucketEvent"

@module(
  "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs"
)
external sqsPublishJsons: ('a, string) => 'b = "publishJsons"

@module("./HandlerFactoryHelpers.res.mjs")
external makeQueueRef: string => 'a = "makeQueueRef"

// === Object/field accessors ===

@get external getCallback: 'a => 'b = "callback"
@get external getTAG: 'a => int = "TAG"
@get external get_0: 'a => 'b = "_0"
@get external get_1: 'a => 'b = "_1"

let callPublish: ('a, 'b) => promise<unit> = %raw(`(fn, cmds) => fn(cmds)`)
let callHandleEvents: ('a, 'b, 'c) => promise<array<'d>> = %raw(`(fn, e, c) => fn(e, c)`)

// === Initialization ===

type s3Handler

let buildHandler = async (): s3Handler => {
  let configStr = env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{}`)
  let config: config = configStr->JSON.parseOrThrow->Obj.magic

  let callbackModule = await dynamicImport(config.callbackModule)
  let bucketCallback = callbackModule->getCallback

  let handleEvents = handleBucketEvent(bucketCallback)

  // Build publishCommands dict from env var queue URLs
  let publishCommandsFns: dict<'a> = Dict.make()
  config.publishToAggregates->Dict.forEachWithKey((envVarName, aggName) => {
    let queueUrl = env->Dict.get(envVarName)->Option.getOr("")
    if queueUrl !== "" {
      publishCommandsFns->Dict.set(aggName, sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO"))
    }
  })

  Obj.magic(async (event, _context) => {
    let taskActions = await callHandleEvents(handleEvents, event, _context)

    let _ = await taskActions
      ->Array.map(async action => {
        let tag = action->getTAG
        switch tag {
        | 0 => {
            // PublishCommands(aggregateName, cmdJsons)
            let aggregateName: string = action->get_0->Obj.magic
            let cmdJsons = action->get_1
            switch publishCommandsFns->Dict.get(aggregateName) {
            | Some(pub) => await callPublish(pub, cmdJsons)
            | None =>
              Console.warn(
                `TaskBucketEntryPoint: No publish function for aggregate "${aggregateName}"`,
              )
            }
          }
        | 1 =>
          Console.warn("TaskBucketEntryPoint: CreateSchedule not supported in bundled mode")
        | 2 =>
          Console.warn("TaskBucketEntryPoint: DeleteSchedule not supported in bundled mode")
        | _ => ()
        }
      })
      ->Promise.all

    ""
  })
}

let initPromise = buildHandler()

// === Exported handler ===

let handler = async (event, context) => {
  let s3Handler = await initPromise
  let result: string = await Obj.magic(s3Handler)(event, context)->Obj.magic
  result
}
