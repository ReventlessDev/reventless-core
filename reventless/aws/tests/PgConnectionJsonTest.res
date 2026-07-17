// Rung-1 guard for the `pgConnection` HANDLER_CONFIG serialization (A3/B/C).
//
// `PgConnection.connectionConfigToJson` is the single producer of the object
// every Postgres entry point reads at cold start (`config.pgConnection.*` →
// `PgRuntime.poolFor`). The field set is an untyped cross-language contract — a
// dropped/renamed/retyped field here only fails at runtime in the deployed
// Lambda, which no compile catches. These tests pin the exact shape so a drift
// fails in CI instead. All seven deploy-time builders now route through this
// helper, so pinning it pins them all.

open JestGlobals

let cc: PgConnection.connectionConfig = {
  host: "db.example.eu-west-1.rds.amazonaws.com",
  port: 5432,
  database: "reventless",
  username: "reventless_admin",
  secretArn: "arn:aws:secretsmanager:eu-west-1:123456789012:secret:rds!db-abc-123",
}

let obj = json => json->JSON.Decode.object->Option.getOrThrow
let field = (json, key) => json->obj->Dict.get(key)

describe("PgConnection.connectionConfigToJson", () => {
  testSync("emits exactly the five connection fields with correct types", () => {
    let json = cc->PgConnection.connectionConfigToJson
    // Exact key set — no extra keys, none missing (the cold-start contract).
    expect(json->obj->Dict.keysToArray->Array.toSorted(String.compare))->toEqual([
      "database",
      "host",
      "port",
      "secretArn",
      "username",
    ])
    expect(json->field("host"))->toEqual(Some(JSON.Encode.string(cc.host)))
    expect(json->field("database"))->toEqual(Some(JSON.Encode.string(cc.database)))
    expect(json->field("username"))->toEqual(Some(JSON.Encode.string(cc.username)))
    expect(json->field("secretArn"))->toEqual(Some(JSON.Encode.string(cc.secretArn)))
    // port MUST be a JSON number (poolFor reads it as an int), not a string.
    expect(json->field("port"))->toEqual(Some(JSON.Encode.float(5432.)))
  })

  testSync("omits lockStrategy when not given (classic / QueryDb / migration paths)", () =>
    expect(cc->PgConnection.connectionConfigToJson->field("lockStrategy"))->toEqual(None)
  )

  testSync("adds lockStrategy=\"AdvisoryLocks\" as the polyvariant string name", () =>
    expect(
      cc
      ->PgConnection.connectionConfigToJson(~lockStrategy=#AdvisoryLocks)
      ->field("lockStrategy"),
    )->toEqual(Some(JSON.Encode.string("AdvisoryLocks")))
  )

  testSync("adds lockStrategy=\"RowLocks\" as the polyvariant string name", () =>
    expect(
      cc
      ->PgConnection.connectionConfigToJson(~lockStrategy=#RowLocks)
      ->field("lockStrategy"),
    )->toEqual(Some(JSON.Encode.string("RowLocks")))
  )

  testSync("with lockStrategy the object has exactly six keys", () =>
    expect(
      cc
      ->PgConnection.connectionConfigToJson(~lockStrategy=#RowLocks)
      ->obj
      ->Dict.keysToArray
      ->Array.length,
    )->toBe(6)
  )

  testSync("round-trips through JSON.parse as the entry points do", () => {
    // The entry point does `JSON.parse(HANDLER_CONFIG).pgConnection` — prove the
    // stringify→parse survives and still exposes the fields poolFor reads.
    let parsed =
      `{"pgConnection":${cc->PgConnection.connectionConfigToJson->JSON.stringify}}`
      ->JSON.parseOrThrow
      ->field("pgConnection")
      ->Option.getOrThrow
    expect(parsed->field("host"))->toEqual(Some(JSON.Encode.string(cc.host)))
    expect(parsed->field("secretArn"))->toEqual(Some(JSON.Encode.string(cc.secretArn)))
  })
})
