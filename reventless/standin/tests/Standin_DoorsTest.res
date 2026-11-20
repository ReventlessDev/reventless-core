open JestGlobals

// A stand-in signs as the real sender does, from what the local platform
// publishes about its doors and nothing else.

let file = JSON.parseOrThrow(`{
  "doors": [
    {"path": "meter", "slice": "MeterCharger", "method": "POST", "secret": "chargers",
     "header": "X-Signature-256", "prefix": "sha256=", "timestampHeader": "X-Signature-Timestamp"},
    {"path": "open", "slice": "OpenFeed", "method": "POST"}
  ],
  "secrets": {"chargers": "s3cret"}
}`)

let doors = switch Standin.Doors.parse(file, ~base="http://localhost:4000/webhooks/") {
| Ok(doors) => doors
| Error(why) => failwith(why)
}

describe("Standin.Doors:", () => {
  testSync("reads where each door is and what it signs with", () => {
    expect(doors->Array.map(d => (d.slice, d.url, d.signing->Option.isSome)))->toEqual([
      ("MeterCharger", "http://localhost:4000/webhooks/meter", true),
      ("OpenFeed", "http://localhost:4000/webhooks/open", false),
    ])
  })

  testSync("signs the timestamp and the body, as the door checks", () => {
    let door = doors->Standin.Doors.find(~slice="MeterCharger")->Option.getOrThrow
    let body = `{"readingId":"r1"}`
    let headers = door->Standin.Doors.headersFor(~body, ~nowSeconds=1_700_000_000.4)
    let expected = Standin.Doors.hmacHex(~secret="s3cret", `1700000000.${body}`)
    expect(headers->Dict.get("X-Signature-Timestamp"))->toEqual(Some("1700000000"))
    expect(headers->Dict.get("X-Signature-256"))->toEqual(Some(`sha256=${expected}`))
  })

  testSync("an open door is posted to unsigned", () => {
    let door = doors->Standin.Doors.find(~slice="OpenFeed")->Option.getOrThrow
    expect(door->Standin.Doors.headersFor(~body="{}", ~nowSeconds=0.)->Dict.keysToArray)->toEqual([
      "content-type",
    ])
  })

  testSync("a door whose secret the file does not hold is refused", () => {
    let file = JSON.parseOrThrow(`{"doors": [{"path": "p", "slice": "S", "secret": "x", "header": "H"}], "secrets": {}}`)
    expect(Standin.Doors.parse(file, ~base="http://h")->Result.isError)->toBe(true)
  })
})
