open JestGlobals

module DSI = Reventless.DcbScopeInference

// --- tiny constructors so the golden vectors read like the spec files ---
let scal = (name): DSI.idField => {name, isList: false}
let arr = (name): DSI.idField => {name, isList: true}
let ev = (eventType, idFields): DSI.eventShape => {eventType, idFields}
let slice = (sliceName, ~command=[], ~consumed=[], ~produced=[], ~partitionHint=?): DSI.sliceShape => {
  sliceName,
  command,
  consumed,
  produced,
  partitionHint,
}

// The online-shop-hybrid catalog boundary, transcribed structurally (NO tag
// annotations — that is the point). AddProduct reads the category lifecycle.
let addProduct = slice(
  "AddProduct",
  ~command=[scal("productId"), scal("categoryId")],
  ~consumed=[ev("ProductAdded", [scal("productId")]), ev("CategoryAdded", [scal("categoryId")]), ev("CategoryArchived", [scal("categoryId")])],
  ~produced=[ev("ProductAdded", [scal("productId"), scal("categoryId")])],
)
let addCategory = slice(
  "AddCategory",
  ~command=[scal("categoryId")],
  ~consumed=[ev("CategoryAdded", []), ev("CategoryArchived", [])],
  ~produced=[ev("CategoryAdded", [scal("categoryId")])],
)
let renameCategory = slice(
  "RenameCategory",
  ~command=[scal("categoryId")],
  ~consumed=[ev("CategoryAdded", []), ev("CategoryRenamed", []), ev("CategoryArchived", [])],
  ~produced=[ev("CategoryRenamed", [scal("categoryId")])],
)
let archiveCategory = slice(
  "ArchiveCategory",
  ~command=[scal("categoryId")],
  ~consumed=[ev("CategoryAdded", []), ev("CategoryArchived", [])],
  ~produced=[ev("CategoryArchived", [scal("categoryId")])],
)
let catalog = [addProduct, addCategory, renameCategory, archiveCategory]

describe("DcbScopeInference:", () => {
  describe("tagKeyOf", () => {
    testSync("scalar *Id uses the field name", () =>
      expect(DSI.tagKeyOf(scal("categoryId")))->toBe("categoryId")
    )
    testSync("plural *Ids strips the trailing s", () =>
      expect(DSI.tagKeyOf(arr("productIds")))->toBe("productId")
    )
  })

  describe("hybrid catalog (no annotations)", () => {
    let d = DSI.infer(catalog)

    testSync("derives categoryId as the only cross-partition key — without any @crossPartition", () =>
      expect(d.crossPartitionTagKeys)->toEqual(["categoryId"])
    )

    testSync("AddProduct partition = productId (foreign categoryId eliminated)", () =>
      expect(d.partitionBySlice->Dict.get("AddProduct"))->toEqual(Some("productId"))
    )

    testSync("Category slices partition = categoryId", () => {
      expect(d.partitionBySlice->Dict.get("AddCategory"))->toEqual(Some("categoryId"))
      expect(d.partitionBySlice->Dict.get("RenameCategory"))->toEqual(Some("categoryId"))
      expect(d.partitionBySlice->Dict.get("ArchiveCategory"))->toEqual(Some("categoryId"))
    })

    testSync("ProductAdded indexes productId only — categoryId is payload (no sibling leak)", () =>
      expect(d.tagKeysByEventType->Dict.get("ProductAdded"))->toEqual(Some(["productId"]))
    )

    testSync("CategoryAdded indexes its own categoryId", () =>
      expect(d.tagKeysByEventType->Dict.get("CategoryAdded"))->toEqual(Some(["categoryId"]))
    )

    testSync("no ambiguities for a well-formed boundary", () =>
      expect(d.ambiguities)->toEqual([])
    )

    testSync("ownerByKey points categoryId at a Category slice, productId at Product", () => {
      expect(d.ownerByKey->Dict.get("productId"))->toEqual(Some("AddProduct"))
      expect(d.ownerByKey->Dict.get("categoryId")->Option.isSome)->toBe(true)
    })
  })

  describe("own composite read + @partitionTag hint (RecordProductDemand shape)", () => {
    // Event carries two owned-looking keys (productId, orderId); the slice reads
    // its OWN stream by both (idempotency). @partitionTag picks productId; orderId
    // must stay indexed because the slice reads its own event type by it.
    let recordDemand = slice(
      "RecordProductDemand",
      ~partitionHint="productId",
      ~consumed=[ev("ProductDemandRecorded", [scal("orderId")]), ev("ProductDemandRevoked", [scal("orderId")])],
      ~produced=[ev("ProductDemandRecorded", [scal("productId"), scal("orderId")]), ev("ProductDemandRevoked", [scal("productId"), scal("orderId")])],
    )
    let d = DSI.infer([recordDemand])

    testSync("the @partitionTag hint resolves the partition (no ambiguity)", () => {
      expect(d.partitionBySlice->Dict.get("RecordProductDemand"))->toEqual(Some("productId"))
      expect(d.ambiguities)->toEqual([])
    })
    testSync("orderId stays indexed — it is an own-stream read key, not a foreign ref", () =>
      expect(d.tagKeysByEventType->Dict.get("ProductDemandRecorded"))->toEqual(
        Some(["orderId", "productId"]),
      )
    )
    testSync("orderId is not cross-partition (no Order entity owns it in this boundary)", () =>
      expect(d.crossPartitionTagKeys)->toEqual([])
    )
  })

  describe("M:N array reference (productIds)", () => {
    // An ordering-style slice reading "all orders for each product" via array tag.
    let placeOrder = slice(
      "PlaceOrder",
      ~command=[scal("orderId"), arr("productIds")],
      ~consumed=[ev("OrderPlaced", [scal("orderId")]), ev("ProductAdded", [scal("productId")])],
      ~produced=[ev("OrderPlaced", [scal("orderId"), arr("productIds")])],
    )
    let productEntity = slice(
      "AddProduct2",
      ~command=[scal("productId")],
      ~consumed=[ev("ProductAdded", [])],
      ~produced=[ev("ProductAdded", [scal("productId")])],
    )
    let d = DSI.infer([placeOrder, productEntity])

    testSync("plural productIds read cross-partition shares the singular producer key", () =>
      expect(d.crossPartitionTagKeys)->toEqual(["productId"])
    )
    testSync("PlaceOrder partition = orderId", () =>
      expect(d.partitionBySlice->Dict.get("PlaceOrder"))->toEqual(Some("orderId"))
    )
    testSync("OrderPlaced indexes orderId only (productIds is a foreign payload ref)", () =>
      expect(d.tagKeysByEventType->Dict.get("OrderPlaced"))->toEqual(Some(["orderId"]))
    )
  })

  // The schema adapter (DcbTag.eventShapesOfSchema / sliceShapeFromSchemas) is the
  // runtime's bridge from `S.t` to the pure boundary type. Exercise it on a REAL
  // annotated fixture schema and show inference reproduces the annotation-based
  // `extractCrossPartitionTagKeys` from the un-annotated structure.
  describe("schema adapter ⇄ inference parity", () => {
    let shapes = Reventless.DcbTag.eventShapesOfSchema(DcbFixtures.subscriptionEventSchema)

    testSync("eventShapesOfSchema extracts *Id fields by name (tag flags ignored)", () => {
      expect(shapes->Array.length)->toBe(1)
      let arm = shapes->Array.getUnsafe(0)
      expect(arm.eventType)->toBe("StudentSubscribed")
      let names = arm.idFields->Array.map(f => f.name)->Array.toSorted(String.compare)
      expect(names)->toEqual(["courseId", "studentId"])
    })

    testSync("inference reproduces extractCrossPartitionTagKeys ⇒ [\"studentId\"]", () => {
      // A Student entity owns studentId; Subscribe (built from the real fixture
      // schema) reads it from the foreign StudentRegistered event.
      let studentEntity = slice(
        "RegisterStudent",
        ~produced=[ev("StudentRegistered", [scal("studentId")])],
      )
      let subscribe: DSI.sliceShape = {
        sliceName: "SubscribeStudent",
        command: [],
        consumed: [ev("StudentRegistered", [scal("studentId")])],
        produced: shapes, // StudentSubscribed({courseId, studentId}) from the schema adapter
        partitionHint: None,
      }
      let d = DSI.infer([studentEntity, subscribe])
      expect(d.crossPartitionTagKeys)->toEqual(
        Reventless.DcbTag.extractCrossPartitionTagKeys(DcbFixtures.subscriptionEventSchema),
      )
      expect(d.partitionBySlice->Dict.get("SubscribeStudent"))->toEqual(Some("courseId"))
    })
  })

  describe("ambiguity surfacing", () => {
    // A pure join: produces an event carrying two foreign keys, owns neither.
    let aOwner = slice("A", ~produced=[ev("AHappened", [scal("aId")])])
    let bOwner = slice("B", ~produced=[ev("BHappened", [scal("bId")])])
    let join = slice(
      "Join",
      ~consumed=[ev("AHappened", [scal("aId")]), ev("BHappened", [scal("bId")])],
      ~produced=[ev("Joined", [scal("aId"), scal("bId")])],
    )
    let d = DSI.infer([aOwner, bOwner, join])

    testSync("a pure-join slice with no own key is reported ambiguous", () => {
      let names = d.ambiguities->Array.map(((n, _)) => n)
      expect(names->Array.includes("Join"))->toBe(true)
    })
    testSync("the well-formed owners are not ambiguous", () => {
      let names = d.ambiguities->Array.map(((n, _)) => n)
      expect(names->Array.includes("A"))->toBe(false)
      expect(names->Array.includes("B"))->toBe(false)
    })
  })
})
