// Asserts the canonical JSON shape produced by encodeUIFragmentEntry — shared
// by both the in-memory and AWS adapters. If this test changes, every console
// parsing the Platform_UIFragments response is affected.

open JestGlobals
open Reventless.Plugin

let panel: panelManifestEntry = {
  fragmentId: "Catalog.Categories.list",
  title: "Categories",
  description: "",
  positions: ["platform-summary"],
  requiredAccess: None,
}

let page: pageManifestEntry = {
  fragmentId: "Catalog.Categories.list",
  title: "Categories",
  menuEntry: {
    label: "Categories",
    icon: None,
    group: None,
    sortOrder: 0,
  },
  requiredAccess: Some("admin"),
}

let state: UiFragments.state = {
  pluginId: "Catalog",
  remoteEntryUrl: "https://cdn.example.com/catalog@1.0/remoteEntry.js",
  panels: [panel],
  pages: [page],
  registeredAt: "2026-05-14T00:00:00.000Z",
  updatedAt: "2026-05-14T00:00:00.000Z",
}

let encoded = Platform_UIFragmentsApi.encodeUIFragmentEntry(state)
let json = encoded->JSON.stringify

describe("encodeUIFragmentEntry", () => {
  testSync("produces a JSON object with the expected top-level keys", () => {
    let dict = encoded->JSON.Decode.object->Option.getOr(Dict.make())
    let keys = dict->Dict.keysToArray->Array.toSorted(String.compare)
    expect(keys)->toEqual([
      "pages",
      "panels",
      "pluginId",
      "registeredAt",
      "remoteEntryUrl",
      "updatedAt",
    ])
  })

  testSync("encodes pluginId", () =>
    expect(json->String.includes("\"pluginId\":\"Catalog\""))->toEqual(true)
  )

  testSync("encodes remoteEntryUrl", () =>
    expect(
      json->String.includes("\"remoteEntryUrl\":\"https://cdn.example.com/catalog@1.0/remoteEntry.js\""),
    )->toEqual(true)
  )

  testSync("encodes None requiredAccess on panel as null", () =>
    expect(json->String.includes("\"requiredAccess\":null"))->toEqual(true)
  )

  testSync("encodes Some requiredAccess on page as its inner string", () =>
    expect(json->String.includes("\"requiredAccess\":\"admin\""))->toEqual(true)
  )

  testSync("encodes nested menuEntry as an object with sortOrder", () =>
    expect(json->String.includes("\"sortOrder\":0"))->toEqual(true)
  )

  testSync("encodes panel positions as an array of strings", () =>
    expect(json->String.includes("\"positions\":[\"platform-summary\"]"))->toEqual(true)
  )
})

describe("Platform_UIFragmentsApi.sdl", () => {
  testSync("query field declares the list type", () =>
    expect(Platform_UIFragmentsApi.sdlQueryField->String.includes("[Platform_UIFragmentEntry!]!"))
    ->toEqual(true)
  )

  testSync("sdlTypes includes Platform_UIFragmentEntry", () => {
    let allTypes = Platform_UIFragmentsApi.sdlTypes->Array.join("\n")
    expect(allTypes->String.includes("Platform_UIFragmentEntry"))->toEqual(true)
  })

  testSync("sdlTypes includes Platform_UIPanel with positions field", () => {
    let allTypes = Platform_UIFragmentsApi.sdlTypes->Array.join("\n")
    expect(allTypes->String.includes("positions: [String!]!"))->toEqual(true)
  })
})
