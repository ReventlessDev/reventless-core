// Guards the typed cold-start core hoisted out of TaskBucketEntryPoint.mjs:
//   - parseHandlerConfig — the callbackModule / publishToAggregates /
//     scheduler env-indirection contract.
//   - buildPublishCommands — env-var queue resolution incl. the skip on
//     unset/empty URLs.
//   - dispatchTaskActions — the exhaustive task-action dispatch (publish
//     routing, schedule create/delete, and the no-scheduler skip paths).

open JestGlobals

let str = JSON.Encode.string
let obj = pairs => JSON.Encode.object(Dict.fromArray(pairs))

@val @scope("process") external processEnv: dict<string> = "env"

describe("TaskBucketEntryPoint_Ops.parseHandlerConfig", () => {
  testSync("empty raw config decodes to empty defaults", () => {
    let c = TaskBucketEntryPoint_Ops.parseHandlerConfig("")
    expect(c.callbackModule)->toBe("")
    expect(c.publishToAggregates->Dict.toArray->Array.length)->toBe(0)
    expect(c.scheduler->Option.isNone)->toBe(true)
  })

  testSync("decodes callbackModule, publishToAggregates, and scheduler env names", () => {
    let config = obj([
      ("callbackModule", str("@x/plugin/src/Task/ImportCatalog.res.mjs")),
      ("publishToAggregates", obj([("Product", str("PTA_Product_QUEUE_URL"))])),
      (
        "scheduler",
        obj([
          ("roleArnEnv", str("SCHEDULER_ROLE_ARN")),
          ("targetArnEnv", str("SCHEDULER_TARGET_ARN")),
          ("targetNameEnv", str("SCHEDULER_TARGET_NAME")),
        ]),
      ),
    ])->JSON.stringify
    let c = TaskBucketEntryPoint_Ops.parseHandlerConfig(config)
    expect(c.callbackModule)->toBe("@x/plugin/src/Task/ImportCatalog.res.mjs")
    expect(c.publishToAggregates->Dict.get("Product"))->toEqual(Some("PTA_Product_QUEUE_URL"))
    switch c.scheduler {
    | Some(s) => expect(s.roleArnEnv)->toBe("SCHEDULER_ROLE_ARN")
    | None => JsError.throwWithMessage("expected Some(scheduler)")
    }
  })
})

describe("TaskBucketEntryPoint_Ops.buildPublishCommands", () => {
  testSync("resolves queue URLs via env vars, skipping unset or empty ones", () => {
    processEnv->Dict.set("TB_TEST_QUEUE_A", "https://sqs/a.fifo")
    processEnv->Dict.set("TB_TEST_QUEUE_EMPTY", "")
    let map = Dict.fromArray([
      ("AggA", "TB_TEST_QUEUE_A"),
      ("AggEmpty", "TB_TEST_QUEUE_EMPTY"),
      ("AggUnset", "TB_TEST_QUEUE_UNSET"),
    ])
    let publish = TaskBucketEntryPoint_Ops.buildPublishCommands(map)
    expect(publish->Dict.get("AggA")->Option.isSome)->toBe(true)
    expect(publish->Dict.get("AggEmpty")->Option.isNone)->toBe(true)
    expect(publish->Dict.get("AggUnset")->Option.isNone)->toBe(true)
  })
})

describe("TaskBucketEntryPoint_Ops.dispatchTaskActions", () => {
  let schedule: Reventless.Schedule.schedule = {
    name: "sweep",
    rate: Reventless.Schedule.Minutes(5),
    payload: "{}",
  }

  test("routes PublishCommands to the aggregate's publish fn", async () => {
    let published = []
    let publishCommands = Dict.fromArray([
      (
        "Product",
        (
          async cmds => {
            published->Array.push(cmds)
          }: ReventlessCore.CommandTopic.publishJsons
        ),
      ),
    ])
    await TaskBucketEntryPoint_Ops.dispatchTaskActions(
      ~actions=[
        Reventless.Task.PublishCommands("Product", []),
        // Unknown aggregate — logged, not thrown.
        Reventless.Task.PublishCommands("Nope", []),
      ],
      ~publishCommands,
      ~schedulerOps=() => None,
    )
    expect(published->Array.length)->toBe(1)
  })

  test("routes schedule actions to the scheduler ops; skips when unconfigured", async () => {
    let created = []
    let deleted = []
    let ops: TaskBucketEntryPoint_Ops.schedulerOps = {
      createSchedule: async s => created->Array.push(s.name),
      deleteSchedule: async name => deleted->Array.push(name),
    }
    await TaskBucketEntryPoint_Ops.dispatchTaskActions(
      ~actions=[Reventless.Task.CreateSchedule(schedule), Reventless.Task.DeleteSchedule("sweep")],
      ~publishCommands=Dict.make(),
      ~schedulerOps=() => Some(ops),
    )
    expect(created)->toEqual(["sweep"])
    expect(deleted)->toEqual(["sweep"])

    // No scheduler configured — both actions skip without throwing.
    await TaskBucketEntryPoint_Ops.dispatchTaskActions(
      ~actions=[Reventless.Task.CreateSchedule(schedule), Reventless.Task.DeleteSchedule("sweep")],
      ~publishCommands=Dict.make(),
      ~schedulerOps=() => None,
    )
    expect(created->Array.length)->toBe(1)
  })
})
