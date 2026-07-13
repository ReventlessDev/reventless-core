// Regression guard for the ApiSchemaPush SideEffect "Source erasure" deploy-only bug.
//
// SideEffectHandler_Callback.Make reads Source.{name,eventSchema,Id} reflectively off
// the imported ApiSchemaPush module at Lambda cold start. ApiSchemaPush only uses Source
// at the TYPE level, so a bare `module Source = …` alias gets dead-shaken by ReScript to
// `let Source;` (undefined) — crashing the handler with "Cannot read properties of
// undefined (reading 'eventSchema')" and hanging the deploy waiter. The `include` in
// ApiSchemaPush.res materialises Source's runtime values. These assertions dereference
// exactly the fields the runtime reads, so a regression (alias reintroduced) fails here
// instead of only on a live deploy.

open JestGlobals

describe("ApiSchemaPush SideEffect Source (runtime materialisation)", () => {
  testSync("Source.name is the registry aggregate name", () => {
    expect(ApiSchemaPush.Source.name)->toBe("ApiFragmentRegistry")
  })

  testSync("Source.eventSchema is a live schema — extractAllVariantNames succeeds", () => {
    // Mirrors SideEffectHandler_Callback.Make: throws if Source is erased to undefined.
    let tags = Reventless.DcbTag.extractAllVariantNames(ApiSchemaPush.Source.eventSchema)
    expect(tags)->toContain("ApiSchemaComputed")
  })

  testSync("Source.Id is a live module — the reflective id round-trip does not crash", () => {
    // SideEffectHandler_Callback reads `Source.Id.schema` on the id-bearing registry events.
    // A bare `module Id` alias compiles to `Id: undefined` in the Source record, so any access
    // (makeFromString/toString/schema) throws "reading 'schema'"/undefined on a regression.
    let id = "registry"->ApiSchemaPush.Source.Id.makeFromString
    expect(id->ApiSchemaPush.Source.Id.toString)->toBe("registry")
  })
})
