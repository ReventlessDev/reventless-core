// End-to-end Postgres projection pipeline (B1 + B3.0 + B3.1 composed), minus AWS.
//
// Skipped unless PG_URL is set. Exercises the full deployed classic path against
// a real database:
//   classic append (`event_log`) → change-feed relay (`relayClassicWithPool`,
//   emitting the EventCollector `{id, meta, event}` bodies) → feed-queue SQS
//   records → `handleStreamEvent` decode → a real `ReadModel_Callback` projection
//   (meta.service dispatch) → `QueryDbStorage_Postgres` write → `qdb_` row.
//
// This is the composition the first live deploy will exercise; the only pieces
// it can't cover are the AWS boundary itself (SQS delivery, ESMs, VPC).

open JestGlobals
open ReventlessCore

@val external processEnv: dict<string> = "process.env"

// --- Fixtures: one classic source, one read model, one projection mapping ---

module OrderSource = {
  module Id = Reventless.Id.StringPure
  let name = "Order"

  @schema
  type event = OrderPlaced({product: string})
}

module OrdersSpec = {
  module Id = Reventless.Id.StringPure
  let name = "PipelineOrders"
  let moduleUrl = ""

  @schema
  type state = {id: string, product: string}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
  let authorization: Reventless.Authorization.permission = AllowAuthenticated
  let visibility: Reventless.Visibility.t = Public
}

module OrderMapping = Reventless.Projection.Mapping.Make(
  OrderSource,
  OrdersSpec,
  {
    let project = ({id, event, _}: Reventless.Message.event'<string, OrderSource.event>) =>
      switch event {
      | OrderPlaced({product}) => Reventless.Projection.Set(id, ({id, product}: OrdersSpec.state))
      }
  },
)

module OrdersMappings = {
  module Target = OrdersSpec
  module M = Reventless.Projection.Mappings.Make(OrdersSpec)
  module type Mapping = M.Mapping
  let moduleUrl = ""
  let mappings: array<module(Mapping)> = [module(OrderMapping)]
}

// --- Helpers ---

// The flat on-disk item the classic append stores verbatim — same shape the
// DynamoDB path puts (id, position, event, data, decomposed meta). `service`
// must be the SOURCE name: ReadModel_Callback dispatches mappings by
// meta.service (the repeatedly-bitten projection dispatch key).
let flatItem = (~id, ~seq, ~service, ~event: OrderSource.event) => {
  let (eventType, data) =
    event
    ->S.reverseConvertToJsonOrThrow(OrderSource.eventSchema)
    ->Message.splitMessage
  [
    ("id", JSON.Encode.string(id)),
    ("position", JSON.Encode.string(seq->Int.toString->String.padStart(9, "0"))),
    ("event", JSON.Encode.string(eventType)),
    ("data", JSON.Encode.object(data)),
  ]
  ->Array.concat(Message.generateMeta(~service)->Message.decomposeMeta)
  ->Dict.fromArray
  ->JSON.Encode.object
}

// Wrap relay bodies the way the deployed feed queue delivers them.
let asSqsEvent = (bodies: array<JSON.t>): PulumiAws.Lambda.CallbackFunction.event =>
  Obj.magic({
    "Records": bodies->Array.map(body =>
      {
        "eventSource": "aws:sqs",
        "eventSourceARN": "arn:aws:sqs:eu-west-1:1:AllReadModelsFeed",
        "body": JSON.stringify(body),
      }
    ),
  })

switch processEnv->Dict.get("PG_URL") {
| None =>
  testSync("Postgres pipeline integration (skipped — set PG_URL to run)", () =>
    expect(true)->toBe(true)
  )
| Some(url) =>
  let pool = ReventlessPostgres.PgDriver.makePool({connectionString: url})

  let qdbOps = ReventlessPostgres.QueryDbStorage_Postgres.makeOperations(
    ~pool,
    ~name=OrdersSpec.name,
    ~indexes=[],
    ~subIdField=None,
  )

  module Callback = ReadModel_Callback.Make(
    OrdersSpec,
    OrdersMappings,
    {
      module ReadModelSpec = OrdersSpec
      // Production passes the raw JSON op set (ReadModelEntryPoint) — actions are
      // rewritten to JSON via stateSchema before handleAction, so the JSON-level
      // ops satisfy the typed slot exactly as deployed.
      let operations: QueryDb.operations<string, OrdersSpec.state> = Obj.magic(qdbOps)
    },
  )

  beforeAllAsync(async () => {
    await ReventlessPostgres.PgSchema.ensureSchema(pool)
    await ReventlessPostgres.PgSchema.truncateAll(pool)
    let _ = await pool->ReventlessPostgres.PgDriver.query(
      `DROP TABLE IF EXISTS qdb_${OrdersSpec.name}`,
      [],
    )
  })
  afterAll(() => {
    let _ = pool->ReventlessPostgres.PgDriver.endPool
  })

  describe("Postgres pipeline (append → relay → feed decode → projection → qdb row)", () => {
    testPromise("projects a classic event end-to-end into the Postgres QueryDb", async () => {
      let (_n, elOps, _s) =
        ReventlessPostgres.EventLogStorage_Postgres.makeStorage(
          ~pool,
          ~name="PipelineOrderEventLog",
          ~opts=(),
        )
      let _ = await elOps.append(
        0,
        "o-1",
        [flatItem(~id="o-1", ~seq=0, ~service=OrderSource.name, ~event=OrderPlaced({product: "boat"}))],
      )

      // Relay drains event_log and emits the EventCollector bodies.
      let sink = ref([])
      let relayed = await PgChangeFeedRelay_Runtime.relayClassicWithPool(
        ~pool,
        ~logName="PipelineOrderEventLog",
        ~subscriber="aws-rm-feed:PipelineOrderEventLog",
        ~sendBatch=async jsons => sink := sink.contents->Array.concat(jsons),
      )
      expect(relayed)->toBe(1)

      // Feed-queue delivery → entry-point decode → real projection callback.
      let _ = await EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent(
        Callback.handleJsonEvents,
        asSqsEvent(sink.contents),
        (),
      )->Effect.runPromise

      // The projected row is in the Postgres QueryDb.
      switch await qdbOps.load("o-1") {
      | Ok(rows) =>
        expect(rows->Array.length)->toBe(1)
        let row = rows->Array.getUnsafe(0)->JSON.Decode.object->Option.getOrThrow
        expect(row->Dict.get("product"))->toEqual(Some(JSON.Encode.string("boat")))
        expect(row->Dict.get("id"))->toEqual(Some(JSON.Encode.string("o-1")))
      | Error(_) => expect("load failed")->toBe("Ok")
      }
    })

    testPromise("meta.service mismatch is a silent no-op (dispatch filter)", async () => {
      let (_n, elOps, _s) =
        ReventlessPostgres.EventLogStorage_Postgres.makeStorage(
          ~pool,
          ~name="PipelineWrongServiceEventLog",
          ~opts=(),
        )
      let _ = await elOps.append(
        0,
        "o-2",
        [flatItem(~id="o-2", ~seq=0, ~service="NotTheSource", ~event=OrderPlaced({product: "x"}))],
      )

      let sink = ref([])
      let _ = await PgChangeFeedRelay_Runtime.relayClassicWithPool(
        ~pool,
        ~logName="PipelineWrongServiceEventLog",
        ~subscriber="aws-rm-feed:PipelineWrongServiceEventLog",
        ~sendBatch=async jsons => sink := sink.contents->Array.concat(jsons),
      )
      let _ = await EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent(
        Callback.handleJsonEvents,
        asSqsEvent(sink.contents),
        (),
      )->Effect.runPromise

      switch await qdbOps.load("o-2") {
      | Ok(rows) => expect(rows->Array.length)->toBe(0)
      | Error(_) => expect("load failed")->toBe("Ok")
      }
    })
  })
}
