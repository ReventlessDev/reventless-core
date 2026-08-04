// Guards the geocode resolver handler's contract — the client door of the
// geocoding capability (D9 half 2), which replaced the Function URL. The Function
// URL served two callers through one `200`/`502` body-vs-status split; this handler
// serves only the browser, through GraphQL, so the contract is simpler:
//
//   a value returned  — an answer (a possibly-empty candidate list)
//   a thrown error    — no answer (the resolver's response mapper turns it into a
//                       GraphQL error, so the client degrades rather than reading
//                       an empty list as "no such address")
//
// The two arms below are the ones reachable without a live AWS Location call: an
// unset index throws (misconfiguration is not a verdict on the address), and an
// empty query returns `[]` (nothing was asked). The success path and the thrown
// service-failure path both need the SDK and stay unasserted here — see the plan's
// Verification note.

open JestGlobals

let setIndex = v => NodeProcess.env->Dict.set("PLACE_INDEX_NAME", v)
let clearIndex = () => NodeProcess.env->Dict.delete("PLACE_INDEX_NAME")

describe("Geocoder_AwsLocation_Resolver_Ops.handler contract", () => {
  test("an unset PLACE_INDEX_NAME throws — a misconfiguration, not a verdict", async () => {
    clearIndex()
    let threw = switch await Geocoder_AwsLocation_Resolver_Ops.handler({
      arguments: {text: "10 Downing Street"},
    }) {
    | _ => false
    | exception _ => true
    }
    // Returning `[]` here would tell the browser this address does not exist, when
    // in fact the deployment has no geocoder — the client must see an error and be
    // able to distinguish the two, which is the whole point of throwing.
    expect(threw)->toBe(true)
    clearIndex()
  })

  test("an empty query is an answer — nothing was asked, so `[]`", async () => {
    setIndex("some-index")
    let results = await Geocoder_AwsLocation_Resolver_Ops.handler({arguments: {text: ""}})
    // The empty text short-circuits in the shared backend before any SDK call, so
    // this arm is reachable in a unit test and returns a true, final empty answer.
    expect(results->Array.length)->toBe(0)
    clearIndex()
  })

  test("a missing text argument is treated as an empty query", async () => {
    setIndex("some-index")
    let results = await Geocoder_AwsLocation_Resolver_Ops.handler({arguments: {}})
    expect(results->Array.length)->toBe(0)
    clearIndex()
  })
})
