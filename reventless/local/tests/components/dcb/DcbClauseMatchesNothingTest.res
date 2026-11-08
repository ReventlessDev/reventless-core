// A query clause with no event type matches nothing, on every local backend: read through it,
// no event comes back; append on condition of it, nothing it matches can conflict.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let partitionTag = Reventless.DcbTag.Simple({key: "chargerId"})

let eventLogOn = async (~name) => {
  module Bus = LocalBus.Make()
  module Storage = LocalDcbEventLogStorage.Make(Bus)
  let s = Storage.make(~name, ~indexes=[], ~partitionTag, ~opts)
  let storage = await s.operations->TestRunner.resolve
  module Log = ReventlessCore.DcbEventLog_Operations.Make({
    let name = name
    let serviceName = name
    let storage = storage
    let publishJson = async (_, _, _) => ()
  })
  let eventLog: ReventlessCore.DcbEventLog.operations = {
    read: Log.read,
    append: Log.append,
    readStream: Log.readStream,
    appendStream: Log.appendStream,
  }
  eventLog
}

let runUnderMemory = async fn => {
  BackendState.setMemory()
  await fn()
}

let runUnderSqlite = async fn => {
  let db = SqliteDriver.openDb(~path=":memory:")
  BackendState.setSqlite(~db, ~path=":memory:")
  await fn()
  BackendState.setMemory()
  db->SqliteDriver.close
}

let charger: Reventless.DcbTag.tag = {key: "chargerId", value: "charger-1"}

let noted: ReventlessInfra.DcbEventLog.rawEvent = {
  eventType: "FaultNoted",
  data: JSON.Encode.object(Dict.fromArray([("chargerId", JSON.Encode.string("charger-1"))])),
  tags: [charger],
  meta: {
    service: "ReadsNothing",
    time: "2024-01-01T00:00:00Z",
    msgId: "noted-1",
    correlationId: "noted-1",
  },
}

let counter = ref(0)
let fresh = prefix => {
  counter := counter.contents + 1
  `${prefix}-${counter.contents->Int.toString}`
}

let backends = [("in-memory", runUnderMemory), ("SQLite", runUnderSqlite)]

backends->Array.forEach(((label, runUnder)) =>
  describe(`a clause with no event type (${label} backend)`, () => {
    testPromise(
      "reads nothing, and as a condition never conflicts",
      async () =>
        await runUnder(
          async () => {
            let log = await eventLogOn(~name=fresh("MatchesNothing"))
            let _ = await log.append([noted])
            let nothing: Reventless.DcbTag.query = [{eventTypes: [], tags: [charger]}]
            let read = (await log.read(~query=nothing)).events->Array.length
            let all = (await log.read(~query=[{tags: [charger]}])).events->Array.length
            // From before the event: a clause that matched it would conflict.
            let appended = await log.append([noted], ~condition={query: nothing})
            expect((read, all, appended->Result.isOk))->toEqual((0, 1, true))
          },
        ),
    )
  })
)
