// Pins four capabilities a trait needs in order to ship a whole slice rather than
// print a copy of one into its host. Nothing depends on them yet; they are
// asserted so a regression surfaces here rather than when someone builds on them.
//
// P1  a @schema variant inside a functor, over an abstract type — a trait owning
//     a surface parameterised by the host's own types.
// P2  @as renaming a payload-bearing constructor. Works, but takes a literal, so
//     a functor parameter cannot reach it: the route that is NOT available.
// P3  the route that is — a wire name computed at instantiation. An event's
//     identity is the schema's TAG literal, not its ReScript constructor, so one
//     type carries N identities and one graft's payload is refused by another's.
// P4  a functor-produced module satisfying StateChangeSlice.Spec/Behavior, which
//     is what `StateChangeSlice_Builder.Make` takes. Its coercions are checked by
//     the compiler: if this file builds, they hold.

open JestGlobals

let unk = S.castToUnknown

// ── P1: a @schema variant declared inside a functor, over an abstract type ─────

module type HostTypes = {
  type category
  let categorySchema: S.t<category>
}

module MakeEvents = (K: HostTypes) => {
  @schema
  type event =
    | Subscribed({recipientId: string, category: @s.matches(K.categorySchema) K.category})
    | Unsubscribed({recipientId: string, category: @s.matches(K.categorySchema) K.category})
}

module ShopCategory = {
  @schema
  type category = OrderConfirmation | ShippingUpdate | Marketing
}

module ShopEvents = MakeEvents({
  type category = ShopCategory.category
  let categorySchema = ShopCategory.categorySchema
})

// ── P2: @as on a payload-bearing constructor ──────────────────────────────────

@schema
type renamed =
  | @as("ProductImageAttached") ImageAttachedR({productId: string})
  | @as("ProductImageRemoved") ImageRemovedR({productId: string})

// ── P3: a wire name computed at instantiation ─────────────────────────────────
// One ReScript type, N wire identities. The trait would own `fact`; the graft
// would pass its own prefix.

type fact =
  | ImageAttached({entityId: string})
  | ImageRemoved({entityId: string})

let factSchema = (~prefix: string): S.t<fact> =>
  S.union([
    S.object(s => {
      s.tag("TAG", prefix ++ "ImageAttached")
      ImageAttached({entityId: s.field("entityId", DcbTag.string)})
    }),
    S.object(s => {
      s.tag("TAG", prefix ++ "ImageRemoved")
      ImageRemoved({entityId: s.field("entityId", DcbTag.string)})
    }),
  ])

let productFacts = factSchema(~prefix="Product")
let categoryFacts = factSchema(~prefix="Category")

// ── P4: does a functor-produced module satisfy StateChangeSlice.Spec/Behavior? ──
// `StateChangeSlice_Builder.Make` takes exactly these two module types, so
// conformance here is the gate on "can a trait ship a whole slice". The
// assertions are the `: Spec` / `: Behavior` coercions below — they are checked
// by the compiler, so this section passing means the file compiled.

module type GraftConfig = {
  // The host's own slice name. Qualifies the events, so two grafts in one plugin
  // cannot read each other's log entries.
  let sliceName: string
  // The HOST's module url, not the trait's — attribution and partition-tag
  // derivation both read it, and the trait's own file is the wrong answer.
  let moduleUrl: string
  // The host's lifecycle, and the edge its commands own.
  type lifecycleState
  let guard: Transition.t<lifecycleState>
  // The host's groups.
  let authorize: Authorization.permission
}

module MakeAttachmentSlice = (H: GraftConfig) => {
  let name = H.sliceName
  let moduleUrl = H.moduleUrl
  module Id = Id.String

  // Trait-fixed: nothing here needs a host name, because the disambiguation
  // lives in the mutation field rather than the constructor.
  @schema
  type command =
    | Attach({entityId: @s.matches(DcbTag.string) string, ref: string})
    | Remove({entityId: @s.matches(DcbTag.string) string, ref: string})

  @schema
  type error = NotAttached | EntityUnknown

  // Only the EVENT surface needs a computed wire name, so only it is hand-built.
  type event = Attached({entityId: string, ref: string}) | Removed({entityId: string, ref: string})
  type consumedEvent = event

  let eventSchema: S.t<event> = S.union([
    S.object(s => {
      s.tag("TAG", H.sliceName ++ "Attached")
      Attached({
        entityId: s.field("entityId", DcbTag.string),
        ref: s.field("ref", S.string),
      })
    }),
    S.object(s => {
      s.tag("TAG", H.sliceName ++ "Removed")
      Removed({
        entityId: s.field("entityId", DcbTag.string),
        ref: s.field("ref", S.string),
      })
    }),
  ])
  let consumedEventSchema = eventSchema

  let commandAuthorization = _ => H.authorize
  type lifecycleState = H.lifecycleState
  let commandTransition = _ => H.guard
  let traits: array<Trait.t> = []
  let readConsistency = ReadConsistency.EscalateOnRetry
}

module MakeAttachmentBehavior = (Spec: StateChangeSlice.Spec) => {
  module Spec = Spec
  type state = {count: int}
  let initialState = {count: 0}
  let evolve = (state, _event) => {count: state.count + 1}
  let decide = (_state, _command) => Ok([])
  let moduleUrl = Spec.moduleUrl
}

// ── The host side: what would be left in ProductImages.res ────────────────────

module ProductShelf = {
  @schema
  type shelfStatus = Listed | Archived | Discontinued
}

module ProductImagesSpec = MakeAttachmentSlice({
  let sliceName = "ProductImages"
  let moduleUrl = "file:///host/ProductImages.res"
  type lifecycleState = ProductShelf.shelfStatus
  let guard = Transition.Guards([ProductShelf.Listed, ProductShelf.Archived])
  let authorize = Authorization.AllowGroups(["Admin", "Merchandiser"])
})

module CategoryImagesSpec = MakeAttachmentSlice({
  let sliceName = "CategoryImages"
  let moduleUrl = "file:///host/CategoryImages.res"
  type lifecycleState = ProductShelf.shelfStatus
  let guard = Transition.Guards([ProductShelf.Listed])
  let authorize = Authorization.AllowGroups(["Admin"])
})

// THE ASSERTIONS. If a functor-produced module could not be a slice, these
// coercions would not compile.
module ProductImages: StateChangeSlice.Spec = ProductImagesSpec
module CategoryImages: StateChangeSlice.Spec = CategoryImagesSpec

module ProductImagesBehavior: StateChangeSlice.Behavior
  with module Spec := ProductImagesSpec = MakeAttachmentBehavior(ProductImagesSpec)

describe("P1 — @schema variant inside a functor, over an abstract type", () => {
  testSync("the functor's event schema names its constructors", () =>
    expect(DcbTag.extractVariantNames(ShopEvents.eventSchema->unk))->toEqual([
      "Subscribed",
      "Unsubscribed",
    ])
  )
  testSync("the abstract field round-trips through the host's own schema", () =>
    expect(
      ShopEvents.Subscribed({
        recipientId: "r1",
        category: ShopCategory.ShippingUpdate,
      })->Util_Sury.toJson(ShopEvents.eventSchema),
    )->toEqual(%raw(`{TAG: "Subscribed", recipientId: "r1", category: "ShippingUpdate"}`))
  )
})

describe("P2 — @as on a payload-bearing constructor", () => {
  testSync("extraction reports the overridden wire name", () =>
    expect(DcbTag.extractVariantNames(renamedSchema->unk))->toEqual([
      "ProductImageAttached",
      "ProductImageRemoved",
    ])
  )
  testSync("the wire payload carries the overridden TAG", () =>
    expect(ImageAttachedR({productId: "p1"})->Util_Sury.toJson(renamedSchema))->toEqual(
      %raw(`{TAG: "ProductImageAttached", productId: "p1"}`),
    )
  )
})

describe("P3 — a wire name computed at instantiation", () => {
  testSync("two instantiations of one type produce distinct wire names", () => {
    expect((
      DcbTag.extractVariantNames(productFacts->unk),
      DcbTag.extractVariantNames(categoryFacts->unk),
    ))->toEqual((
      ["ProductImageAttached", "ProductImageRemoved"],
      ["CategoryImageAttached", "CategoryImageRemoved"],
    ))
  })

  testSync("the computed names are byte-identical to the committed graft's", () =>
    expect(
      DcbTag.extractVariantNames(productFacts->unk)->Array.includes("ProductImageAttached"),
    )->toBe(true)
  )

  testSync("a value encodes under its instantiation's name", () =>
    expect(ImageAttached({entityId: "p1"})->Util_Sury.toJson(productFacts))->toEqual(
      %raw(`{TAG: "ProductImageAttached", entityId: "p1"}`),
    )
  )

  testSync("the same value encodes differently under the other instantiation", () =>
    expect(ImageAttached({entityId: "c1"})->Util_Sury.toJson(categoryFacts))->toEqual(
      %raw(`{TAG: "CategoryImageAttached", entityId: "c1"}`),
    )
  )

  testSync("DCB tag extraction still sees the tagged field", () =>
    expect(
      DcbTag.extractTagsFromJson(
        productFacts->unk,
        ImageAttached({entityId: "p1"})->Util_Sury.toJson(productFacts),
      ),
    )->toEqual([{DcbTag.key: "entityId", value: "p1"}])
  )

  // The direction a slice's `evolve` actually runs in. Encoding alone would pass
  // even if the TAG were cosmetic.
  testSync("the wire name decodes back to the shared ReScript constructor", () =>
    expect(
      %raw(`{TAG: "ProductImageRemoved", entityId: "p1"}`)->Util_Sury.fromJson(productFacts),
    )->toEqual(ImageRemoved({entityId: "p1"}))
  )

  // The assertion the whole idea rests on: one graft's log entry must not decode
  // as another's. Without this, "distinct names" is decoration.
  testSync("the other instantiation's payload is REFUSED, not silently accepted", () => {
    let foreign = %raw(`{TAG: "CategoryImageAttached", entityId: "c1"}`)
    let decoded = try Some(foreign->Util_Sury.fromJson(productFacts)) catch {
    | _ => None
    }
    expect(decoded)->toEqual(None)
  })
})

describe("P4 — a functor-produced module IS a StateChangeSlice spec", () => {
  // The conformance itself is checked by the compiler (the `: StateChangeSlice.Spec`
  // coercions above). These assert the two instantiations are genuinely distinct
  // rather than sharing one module.
  testSync("each instantiation carries its own component name", () =>
    expect((ProductImages.name, CategoryImages.name))->toEqual(("ProductImages", "CategoryImages"))
  )

  testSync("the event surface is qualified per graft, with no config to get wrong", () =>
    expect((
      DcbTag.extractVariantNames(ProductImages.eventSchema->unk),
      DcbTag.extractVariantNames(CategoryImages.eventSchema->unk),
    ))->toEqual((
      ["ProductImagesAttached", "ProductImagesRemoved"],
      ["CategoryImagesAttached", "CategoryImagesRemoved"],
    ))
  )

  // Constructed through the uncoerced modules: sealing to `Spec` makes `command`
  // abstract, which is right — the runtime only ever decodes one off the wire.
  testSync("each graft keeps its own authorization", () =>
    expect((
      ProductImagesSpec.commandAuthorization(
        ProductImagesSpec.Attach({
          entityId: "p1",
          ref: "r",
        }),
      ),
      CategoryImagesSpec.commandAuthorization(
        CategoryImagesSpec.Attach({
          entityId: "c1",
          ref: "r",
        }),
      ),
    ))->toEqual((
      Authorization.AllowGroups(["Admin", "Merchandiser"]),
      Authorization.AllowGroups(["Admin"]),
    ))
  )

  // The gap this probe does NOT close. Trait-fixed command names are identical
  // across grafts, so `Plugin_Structure`'s dcbCommandOwners check would refuse
  // this plugin and `Api_Naming` would emit `${plugin}_Attach` twice. Qualifying
  // the mutation field and the routing key by slice is the outstanding work.
  testSync("commands are NOT yet distinct — the routing key and mutation field are", () =>
    expect(
      DcbTag.extractAllVariantNames(ProductImages.commandSchema->unk) ==
        DcbTag.extractAllVariantNames(CategoryImages.commandSchema->unk),
    )->toBe(true)
  )
})
