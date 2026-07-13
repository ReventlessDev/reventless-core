// Asserts the canonical JSON shape produced by encodeApiFragmentEntry — the
// deploy-facing status surface of the API-schema fragment registry, shared by
// the in-memory and AWS adapters. Status only (no encoded SDL). If this test
// changes, any deploy waiter parsing Platform_ApiFragments is affected.

open JestGlobals

let state: ApiFragmentsReadModelSpec.state = {
  pluginId: "Catalog",
  encoded: `{"types":[],"mutations":[],"queries":[],"subscriptions":[],"subscriptionSources":[]}`,
  protocol: "graphql",
  apiTarget: Reventless.Plugin.Domain,
  registeredAt: "2026-05-14T00:00:00.000Z",
  updatedAt: "2026-05-14T00:00:00.000Z",
  pushStatus: "ok",
  pushMessage: "",
  pushedAt: "2026-05-14T00:00:01.000Z",
}

let encoded = Platform_ApiFragmentsApi.encodeApiFragmentEntry(state)
let json = encoded->JSON.stringify

describe("encodeApiFragmentEntry", () => {
  testSync("produces a JSON object with the expected top-level keys (status only, no SDL)", () => {
    let dict = encoded->JSON.Decode.object->Option.getOr(Dict.make())
    let keys = dict->Dict.keysToArray->Array.toSorted(String.compare)
    expect(keys)->toEqual([
      "apiTarget",
      "pluginId",
      "pushMessage",
      "pushStatus",
      "pushedAt",
      "registeredAt",
      "updatedAt",
    ])
  })

  testSync("encodes pluginId", () =>
    expect(json->String.includes("\"pluginId\":\"Catalog\""))->toEqual(true)
  )

  testSync("encodes the apiTarget variant as its bare string", () =>
    expect(json->String.includes("\"apiTarget\":\"Domain\""))->toEqual(true)
  )

  testSync("encodes pushStatus", () =>
    expect(json->String.includes("\"pushStatus\":\"ok\""))->toEqual(true)
  )

  testSync("does not leak the encoded SDL into the status shape", () =>
    expect(json->String.includes("subscriptionSources"))->toEqual(false)
  )
})

describe("Platform_ApiFragmentsApi.sdl", () => {
  testSync("query field declares the list type", () =>
    expect(Platform_ApiFragmentsApi.sdlQueryField->String.includes("[Platform_ApiFragmentEntry!]!"))
    ->toEqual(true)
  )

  testSync("sdlTypes includes Platform_ApiFragmentEntry with pushStatus field", () => {
    let allTypes = Platform_ApiFragmentsApi.sdlTypes->Array.join("\n")
    expect(allTypes->String.includes("Platform_ApiFragmentEntry"))->toEqual(true)
    expect(allTypes->String.includes("pushStatus: String!"))->toEqual(true)
  })
})
