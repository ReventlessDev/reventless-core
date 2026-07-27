// Guards the pure logic hoisted out of the two admin-query resolver Lambdas'
// former inline JS strings (Platform_UIFragments, Platform_ComponentDefinitions)
// into the shared, type-checked Platform_AdminScan_Ops:
//   - `compareVersions` — a byte-for-byte port of the JS `cmpVer` comparator.
//   - `latestByName`    — the highest-version-per-plugin-name collapse.
// The DynamoDB scan itself is an SDK call, not unit-tested here.

open JestGlobals

let cmp = Platform_AdminScan_Ops.compareVersions

describe("Platform_AdminScan_Ops.compareVersions", () => {
  testSync("orders numeric segments as numbers, not lexically", () => {
    // Lexical order would put "10" < "9"; numeric order is the opposite.
    expect(cmp("1.10.0", "1.9.0"))->toBe(1)
    expect(cmp("1.9.0", "1.10.0"))->toBe(-1)
  })

  testSync("equal versions compare to 0", () => {
    expect(cmp("2.3.4", "2.3.4"))->toBe(0)
  })

  testSync("a longer version outranks its prefix", () => {
    // "1.2" normalises to ["1","2"]; "1.2.1" adds a segment (1 > missing "").
    expect(cmp("1.2.1", "1.2"))->toBe(1)
    expect(cmp("1.2", "1.2.1"))->toBe(-1)
  })

  testSync("normalises pre-release `-`/`+` separators to `.`", () => {
    // "1.2.0-1" -> ["1","2","0","1"] outranks "1.2.0" -> ["1","2","0"].
    expect(cmp("1.2.0-1", "1.2.0"))->toBe(1)
  })

  testSync("falls back to lexical order for non-numeric segments", () => {
    expect(cmp("1.2.beta", "1.2.alpha"))->toBe(1)
    expect(cmp("1.2.alpha", "1.2.beta"))->toBe(-1)
  })
})

// A minimal DDB-row (attribute -> JSON value) for the collapse tests.
let row = pairs => Dict.fromArray(pairs)
let s = JSON.Encode.string

describe("Platform_AdminScan_Ops.latestByName", () => {
  // A trivial entry builder that echoes the resolved bare name; drops rows with
  // no `keep` attribute (exercises the toEntry=None skip path).
  let nameVersionOf = item => item->Dict.get("name")->Option.flatMap(JSON.Decode.string)
  let toEntry = (item, ~name) =>
    switch item->Dict.get("keep") {
    | Some(_) => Some(JSON.Encode.object(Dict.fromArray([("pluginId", s(name))])))
    | None => None
    }

  let pluginIdOf = json =>
    json->JSON.Decode.object->Option.flatMap(o => o->Dict.get("pluginId"))->Option.flatMap(JSON.Decode.string)

  testSync("keeps only the highest version per bare plugin name", () => {
    let items = [
      row([("name", s("Catalog@1.9.0")), ("keep", s("y"))]),
      row([("name", s("Catalog@1.10.0")), ("keep", s("y"))]),
      row([("name", s("Catalog@1.2.0")), ("keep", s("y"))]),
      row([("name", s("Ordering@2.0.0")), ("keep", s("y"))]),
    ]
    let out = Platform_AdminScan_Ops.latestByName(items, ~nameVersionOf, ~toEntry)
    let names = out->Array.filterMap(pluginIdOf)
    // One entry per bare name.
    expect(out->Array.length)->toBe(2)
    expect(names->Array.includes("Catalog"))->toBe(true)
    expect(names->Array.includes("Ordering"))->toBe(true)
  })

  testSync("drops rows the entry builder rejects", () => {
    let items = [
      row([("name", s("Catalog@1.0.0"))]), // no `keep` -> dropped
      row([("name", s("Ordering@1.0.0")), ("keep", s("y"))]),
    ]
    let out = Platform_AdminScan_Ops.latestByName(items, ~nameVersionOf, ~toEntry)
    expect(out->Array.filterMap(pluginIdOf))->toEqual(["Ordering"])
  })
})
