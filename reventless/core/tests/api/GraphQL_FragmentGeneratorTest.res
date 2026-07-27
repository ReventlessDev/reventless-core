open JestGlobals

// A multi-variant command union serializes as a sury `Union`, the same shape an
// aggregate command produces. The generator must decide whether to inject the
// aggregate-style `id: ID!` argument from the entry's `injectIdArg` flag, not
// from the schema shape — otherwise a multi-variant DCB slice (e.g. CancelOrder
// + @noApi ReopenOrder) wrongly inherits a spurious `id: ID!` and callers that
// send only the slice's own key field get `MissingFieldArgument: id`.
module OrderSliceCmd = {
  @schema
  type command =
    | CancelOrder({orderId: string})
    | ReopenOrder({orderId: string})
}

let mutationFor = (fragment, needle) =>
  GraphQL_Stitcher.decode(fragment).mutations->Array.find(m => m->String.includes(needle))

describe("GraphQL_FragmentGenerator.generate mutation id injection", () => {
  testSync("multi-variant slice entry (injectIdArg: false) omits the id argument", () => {
    let fragment = GraphQL_FragmentGenerator.generate(
      ~mutationEntries=[
        {
          ReventlessInfra.Api.fieldNames: ["Ordering_CancelOrder"],
          commandSchema: OrderSliceCmd.commandSchema->S.castToUnknown,
          injectIdArg: false,
        },
      ],
      ~queryEntries=[],
    )
    let field = mutationFor(fragment, "Ordering_CancelOrder")->Option.getOr("")
    expect(field->String.includes("orderId"))->toBe(true)
    expect(field->String.includes("id: ID!"))->toBe(false)
  })

  testSync("aggregate-style entry (default) injects id: ID! ahead of the payload", () => {
    let fragment = GraphQL_FragmentGenerator.generate(
      ~mutationEntries=[
        {
          ReventlessInfra.Api.fieldNames: ["Ordering_CancelOrder"],
          commandSchema: OrderSliceCmd.commandSchema->S.castToUnknown,
        },
      ],
      ~queryEntries=[],
    )
    let field = mutationFor(fragment, "Ordering_CancelOrder")->Option.getOr("")
    expect(field->String.includes("id: ID!, orderId"))->toBe(true)
  })
})
