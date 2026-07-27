// Guards the typed cold-start core hoisted out of PgQueryResolverEntryPoint.mjs:
//   - parseResolverConfig — the {pgConnection, handlers, nodeTypes} shape
//     written by PgQueryResolver_Builder; a drift here silently drops a
//     Postgres read model's GraphQL bindings (or its Relay node types) at
//     cold start.

open JestGlobals

describe("PgQueryResolverEntryPoint_Ops.parseResolverConfig", () => {
  testSync("empty raw config yields no connection and no handlers", () => {
    let config = PgQueryResolverEntryPoint_Ops.parseResolverConfig("")
    expect(config.pgConnection->Option.isNone)->toBe(true)
    expect(config.handlers->Array.length)->toBe(0)
    expect(config.nodeTypes->Dict.keysToArray->Array.length)->toBe(0)
  })

  testSync("null pgConnection decodes to None", () => {
    let config = PgQueryResolverEntryPoint_Ops.parseResolverConfig(
      `{"pgConnection":null,"handlers":[]}`,
    )
    expect(config.pgConnection->Option.isNone)->toBe(true)
  })

  testSync("decodes connection, handlers, and node types", () => {
    let config = PgQueryResolverEntryPoint_Ops.parseResolverConfig(
      `{"pgConnection":{"host":"db.local","port":5432,"database":"app","username":"master","secretArn":"arn:secret"},"handlers":[{"readModelName":"Products","specModule":"@x/p/src/ReadModel/Products.res.mjs","labelField":"name","includeIdParam":true},{"readModelName":"Orders","specModule":"@x/p/src/ReadModel/Orders.res.mjs","labelField":"id","includeIdParam":false}],"nodeTypes":{"Product":"Products"}}`,
    )
    expect(config.pgConnection->Option.map(cc => cc.host))->toEqual(Some("db.local"))
    expect(config.handlers->Array.length)->toBe(2)
    let first = config.handlers->Array.getUnsafe(0)
    expect(first.readModelName)->toBe("Products")
    expect(first.specModule)->toBe("@x/p/src/ReadModel/Products.res.mjs")
    expect(first.labelField)->toBe("name")
    expect(first.includeIdParam)->toBe(true)
    expect((config.handlers->Array.getUnsafe(1)).includeIdParam)->toBe(false)
    expect(config.nodeTypes->Dict.get("Product"))->toEqual(Some("Products"))
  })
})
