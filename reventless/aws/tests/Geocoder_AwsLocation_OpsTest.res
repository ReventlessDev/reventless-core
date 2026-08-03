// Guards the geocoder Function URL's *status* contract, which is the whole
// reason one endpoint can serve two callers that want opposite things from it.
//
// A browser search box reads the body and must degrade quietly: never an error,
// just no results. An unattended translator reads the status, because it has to
// tell "there is no such address" (write a verdict, do not retry) from "the
// service cannot answer" (retry). The two only ever disagree about which half of
// the response they read, so:
//
//   200 + a possibly-empty array  — an answer
//   anything else                 — no answer
//
// The arms below are the ones reachable without a live AWS Location call. The
// success path and the thrown-error path both need the SDK and stay unasserted
// here — see the plan's Verification note.

open JestGlobals

let setIndex = v => NodeProcess.env->Dict.set("PLACE_INDEX_NAME", v)
let clearIndex = () => NodeProcess.env->Dict.delete("PLACE_INDEX_NAME")

describe("Geocoder_AwsLocation_Ops.handler status contract", () => {
  test("an unset PLACE_INDEX_NAME is a service failure, not a verdict", async () => {
    clearIndex()
    let resp = await Geocoder_AwsLocation_Ops.handler({
      queryStringParameters: Dict.fromArray([("q", "10 Downing Street")]),
    })
    // The arm that matters most: `200 []` here would tell a translator this
    // address does not exist, and it would record that permanently — for every
    // address handed to it while the deployment stayed misconfigured.
    expect(resp.statusCode)->toBe(502)
    expect(resp.body)->toBe("[]")
  })

  test("an empty query is an answer — nothing was asked", async () => {
    setIndex("some-index")
    let resp = await Geocoder_AwsLocation_Ops.handler({
      queryStringParameters: Dict.fromArray([("q", "")]),
    })
    // 200, unlike the case above: "no results for nothing" is true and final,
    // and a search box sends exactly this on every cleared input.
    expect(resp.statusCode)->toBe(200)
    expect(resp.body)->toBe("[]")
    clearIndex()
  })

  test("a missing q param is treated as an empty one", async () => {
    setIndex("some-index")
    let resp = await Geocoder_AwsLocation_Ops.handler({})
    expect(resp.statusCode)->toBe(200)
    clearIndex()
  })
})

describe("Geocoder_AwsLocation_Ops.readQueryParam", () => {
  testSync("prefers the parsed params", () => {
    expect(
      Geocoder_AwsLocation_Ops.readQueryParam({
        queryStringParameters: Dict.fromArray([("q", "Berlin")]),
      }),
    )->toEqual(Some("Berlin"))
  })

  testSync("falls back to the raw query string, percent-decoded", () => {
    // Payload format 2.0 populates both fields, but a caller that builds its own
    // URL is the reason the fallback exists — and the encoding is where a plain
    // `split("=")` would hand back `10%20Downing%20Street`.
    expect(
      Geocoder_AwsLocation_Ops.readQueryParam({
        rawQueryString: "lang=en&q=10%20Downing%20Street",
      }),
    )->toEqual(Some("10 Downing Street"))
  })

  testSync("no q anywhere is None", () => {
    expect(Geocoder_AwsLocation_Ops.readQueryParam({rawQueryString: "lang=en"}))->toEqual(None)
  })
})
