// The `<trail>Entered` field resolver answers from the row's derived attributes,
// without a data source call. Run here over a row, with the AppSync runtime's
// early return stood in.

open JestGlobals

external asString: Pulumi.Input.t<string> => string = "%identity"

let run: (string, JSON.t) => JSON.t = %raw(`function(code, source) {
  const body = code.replace(/^import .*$/m, '').replace(/export function/g, 'function');
  const runtime = { earlyReturn: v => { throw { early: v } } };
  const request = new Function('runtime', body + '; return request;')(runtime);
  try { request({ source }); } catch (e) { if (e && 'early' in e) return e.early; throw e; }
  throw new Error('no early return');
}`)

let row = (fields: array<(string, JSON.t)>) => fields->Dict.fromArray->JSON.Encode.object

describe("the trail's dates on DynamoDB", () => {
  testSync("reads each visited state and the current one off the attributes", () => {
    let code = QueryDbResolvers_TrailEntered.code()->asString
    let result = run(
      code,
      row([
        ("orderId", JSON.Encode.string("o-1")),
        ("_entered_Placed", JSON.Encode.string("11")),
        ("_entered_Placed_first", JSON.Encode.string("09")),
        ("_visits_Placed", JSON.Encode.int(2)),
        ("_entered_Cancelled", JSON.Encode.string("10")),
        ("_entered_Cancelled_first", JSON.Encode.string("10")),
        ("_visits_Cancelled", JSON.Encode.int(1)),
        ("_entered_current", JSON.Encode.string("11")),
      ]),
    )
    // The same object the local backend reads, from the same attributes.
    expect(result)->toEqual(
      Reventless.Lifecycle.Trail.readEntered(
        Dict.fromArray([
          ("_entered_Placed", JSON.Encode.string("11")),
          ("_entered_Placed_first", JSON.Encode.string("09")),
          ("_visits_Placed", JSON.Encode.int(2)),
          ("_entered_Cancelled", JSON.Encode.string("10")),
          ("_entered_Cancelled_first", JSON.Encode.string("10")),
          ("_visits_Cancelled", JSON.Encode.int(1)),
          ("_entered_current", JSON.Encode.string("11")),
        ]),
      ),
    )
    expect(
      result
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("placed"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(o => o->Dict.get("visits")),
    )->toEqual(Some(JSON.Encode.int(2)))
  })

  testSync("a row stored before the dates were derived reads no dates", () =>
    expect(run(QueryDbResolvers_TrailEntered.code()->asString, row([])))->toEqual(
      row([("current", JSON.Encode.null)]),
    )
  )
})
