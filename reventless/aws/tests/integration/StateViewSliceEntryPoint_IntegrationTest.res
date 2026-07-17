// Integration regression guard for the StateViewSlice projection Lambda entry
// point (`StateViewSliceEntryPoint.mjs`), run against DynamoDB Local.
//
// Covers the 2026-07-09 incident: the deployed runtime built its projection
// loop with `handleAction(action, queryDbOps, undefined)` — hardcoding
// `subIdConfig` to `undefined` instead of threading the slice's
// `specModule.subIdConfig`. Every sub-id-dependent action (`UpdateMultiState`)
// then hit the `MissingSubIdConfig` guard and silently wrote nothing, while the
// in-memory GWT/callback path (which threads `subIdConfig`) stayed green. This
// is a deployed-runtime vs test-harness parity gap: a unit test on the callback
// path cannot catch it, so this test drives the *real* `.mjs` entry point that
// production uses.
//
// The fixture `SvsTestSlice` is an `@subId productId` view slice whose only
// projection path is `UpdateMultiState`. Before the fix both appends no-op and
// the table stays empty; after the fix each product is a distinct row.
//
// Boots via the same `pnpm run test:integration` Docker-gated suite as the DCB
// entry-point test; reuses `DcbIntegrationHarness` for table lifecycle commands.

open JestGlobals

module H = DcbIntegrationHarness

let s = JSON.Encode.string

// A view table for a `@subId` slice is a composite-key table: HASH `id`
// (primary id attribute injected by the QueryDb runtime) + RANGE `productId`
// (the slice's `subIdField`, carried as a plain attribute of each state row).
let createViewTable = async (tableName): Util_DynamoDb_Runtime.resolvedTable => {
  let attrDef = name =>
    Dict.fromArray([("AttributeName", s(name)), ("AttributeType", s("S"))])->JSON.Encode.object
  let keyEl = (name, keyType) =>
    Dict.fromArray([("AttributeName", s(name)), ("KeyType", s(keyType))])->JSON.Encode.object
  let input =
    Dict.fromArray([
      ("TableName", s(tableName)),
      ("AttributeDefinitions", [attrDef("id"), attrDef("productId")]->JSON.Encode.array),
      ("KeySchema", [keyEl("id", "HASH"), keyEl("productId", "RANGE")]->JSON.Encode.array),
      ("BillingMode", s("PAY_PER_REQUEST")),
    ])->JSON.Encode.object
  let _ = await H.send(H.createTableCommand(input))
  {
    Util_DynamoDb_Runtime.id: tableName,
    name: tableName,
    arn: `arn:aws:dynamodb:local:000000000000:table/${tableName}`,
    hashKey: "id",
  }
}

// Drives the real entry point: builds the handler via its exported
// `buildJsonEventsHandler` factory (DynamoDB path — `pgConnection`/`stateTopicName`
// undefined), feeds one encoded event through the effect Stream, and runs the
// resulting Effect through the request context the production handler supplies.
let runOneEvent: (string, JSON.t) => promise<unit> = %raw(`
  async (tableName, eventJson) => {
    const { buildJsonEventsHandler } = await import(
      "@reventlessdev/reventless-aws/src/adapter/Runtime/StateViewSliceEntryPoint.mjs"
    );
    const specModule = await import("./SvsTestSlice.res.mjs");
    const projectionModule = await import("./SvsTestSlice_Projection.res.mjs");
    const Effect = await import("effect/Effect");
    const Stream = await import("effect/Stream");
    const { tag: requestContextTag } = await import(
      "@reventlessdev/reventless-core/src/RequestContext.res.mjs"
    );

    const handler = buildJsonEventsHandler(specModule, projectionModule, tableName, undefined, undefined);
    const stream = Stream.fromIterable([eventJson]);
    const effect = handler(stream)
      .pipe(Effect.provideService(requestContextTag, { correlationId: "svs-test" }));
    await Effect.runPromise(effect);
  }
`)

// Encode the consumed event exactly as the runtime decodes it: the entry point
// calls `parseJsonOrThrow(eventJson, consumedEventSchema)`, so we produce the
// JSON via the same schema to guarantee a faithful round-trip.
let encodeEvent = (event): JSON.t =>
  event->S.reverseConvertToJsonOrThrow(SvsTestSlice.consumedEventSchema)

describe("StateViewSliceEntryPoint integration", () => {
  testAsync(
    "UpdateMultiState on an @subId view slice persists a row per product (was silent no-op)",
    async () => {
      let table = await createViewTable("SvsIt_" ++ Date.now()->Float.toString)

      // Two products added to the same cart → two distinct sub-id rows under the
      // same primary id. The second append also reads back the first row, so a
      // dropped `subIdConfig` (the bug) leaves the table empty at both steps.
      await runOneEvent(
        table.name,
        encodeEvent(ItemAddedToCart({cartId: "cart-1", productId: "prod-a", qty: 2})),
      )
      await runOneEvent(
        table.name,
        encodeEvent(ItemAddedToCart({cartId: "cart-1", productId: "prod-b", qty: 5})),
      )

      let rows = switch await QueryDbStorage_DynamoDb_Runtime.load(table)("cart-1") {
      | Ok(rows) => rows
      | Error(_) => []
      }

      // Before the fix: 0 rows (both UpdateMultiState actions no-op with
      // `MissingSubIdConfig`). After the fix: one row per product.
      expect(rows->Array.length)->toBe(2)

      let productIds =
        rows
        ->Array.filterMap(row =>
          row
          ->JSON.Decode.object
          ->Option.flatMap(o => o->Dict.get("productId"))
          ->Option.flatMap(JSON.Decode.string)
        )
        ->Array.toSorted(String.compare)
      expect(productIds)->toEqual(["prod-a", "prod-b"])

      await H.deleteTable(table)
    },
  )
})
