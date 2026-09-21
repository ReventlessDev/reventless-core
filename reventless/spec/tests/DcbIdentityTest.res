// A typed id is tagged by its identity, not its name. `buyer: CustomerId.t`
// writes the `customerId` tag its producers write, and the partition inference
// reasons about the same key, so retyping a field cannot move its tags.

open JestGlobals

let unk = s => s->S.castToUnknown

module CustomerId = Id.Make({
  let key = "customerId"
})
module ProductId = Id.Make({
  let key = "productId"
})

let customer = CustomerId.schema->DcbTag.mark
let seller = CustomerId.schema->DcbTag.markForKey(~key="sellerId")
let products = S.array(ProductId.schema->DcbTag.mark)

module Slice = {
  @schema
  type command = RegisterBuyer({buyer: @s.matches(customer) CustomerId.t, name: string})

  @schema
  type consumedEvent = BuyerRegistered({buyer: @s.matches(customer) CustomerId.t})

  @schema
  type event =
    | BuyerRegistered({
        buyer: @s.matches(customer) CustomerId.t,
        sellerId: @s.matches(seller) CustomerId.t,
        wishlist: @s.matches(products) array<ProductId.t>,
      })
}

// One id, not named `*Id`: without its type the slice has nothing to be
// partitioned by.
module Rename = {
  @schema
  type command = RenameBuyer({buyer: @s.matches(customer) CustomerId.t, name: string})

  @schema
  type consumedEvent = BuyerRenamed({buyer: @s.matches(customer) CustomerId.t})

  @schema
  type event = BuyerRenamed({buyer: @s.matches(customer) CustomerId.t, name: string})
}

let registered = Slice.BuyerRegistered({
  buyer: CustomerId.make("c-1"),
  sellerId: CustomerId.make("c-2"),
  wishlist: [ProductId.make("p-1"), ProductId.make("p-2")],
})

describe("a typed id is tagged by its identity", () => {
  testSync("the tag key follows the type, and an explicit key still wins", () =>
    expect(DcbTag.extractTagsExpanded(Slice.eventSchema, registered))->toEqual([
      {DcbTag.key: "customerId", value: "c-1"},
      {key: "sellerId", value: "c-2"},
      {key: "productId", value: "p-1"},
      {key: "productId", value: "p-2"},
    ])
  )

  testSync("the index is named after the key its tags carry", () =>
    expect(DcbTag.extractTaggedFields(Slice.eventSchema))->toEqual(["customerId", "sellerId"])
  )

  testSync("a type-preserving marker keeps the identity", () =>
    expect(Semantic.identityKey(customer))->toEqual(Some("customerId"))
  )
})

describe("the partition inference reads identities", () => {
  let shape = DcbTag.sliceShapeFromSchemas(
    ~name="RegisterBuyer",
    ~commandSchema=Slice.commandSchema->unk,
    ~consumedEventSchema=Slice.consumedEventSchema->unk,
    ~eventSchema=Slice.eventSchema->unk,
  )

  testSync("a field not named `*Id` is an id by its type", () =>
    expect(shape.command->Array.map(DcbScopeInference.tagKeyOf))->toEqual(["customerId"])
  )

  testSync("the produced keys are the tag keys", () =>
    expect(DcbScopeInference.producedKeys(shape))->toEqual(["customerId", "productId", "sellerId"])
  )

  testSync("the slice is partitioned by the identity it reads and writes", () => {
    let rename = DcbTag.sliceShapeFromSchemas(
      ~name="RenameBuyer",
      ~commandSchema=Rename.commandSchema->unk,
      ~consumedEventSchema=Rename.consumedEventSchema->unk,
      ~eventSchema=Rename.eventSchema->unk,
    )
    expect(
      DcbScopeInference.resolvePartitions([rename]).partitionBySlice->Dict.get("RenameBuyer"),
    )->toEqual(Some("customerId"))
  })
})

// A schema holds one semantic, so `@ref` on an identity-typed field would erase
// the identity if the reference did not carry it.
describe("a reference to an identity", () => {
  let referenced = CustomerId.schema->Reference.mark("Customers")

  testSync("keeps the identity on its target", () =>
    expect(Reference.getTarget(referenced->unk)->Option.flatMap(t => t.identity))->toEqual(
      Some("customerId"),
    )
  )

  testSync("is tagged by the identity", () =>
    expect(DcbTag.resolveTagKey("buyer", referenced->unk))->toEqual("customerId")
  )
})
