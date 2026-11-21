open JestGlobals

module DSI = Reventless.DcbScopeInference

// --- tiny constructors so the golden vectors read like the spec files ---
let scal = (name): DSI.idField => {name, isList: false}
let arr = (name): DSI.idField => {name, isList: true}
// `@crossPartition`, which also declares the tag.
let cross = (name): DSI.idField => {name, isList: false, declared: true, crossPartition: true}
let ev = (eventType, idFields): DSI.eventShape => {eventType, idFields}
let slice = (
  sliceName,
  ~command=[],
  ~consumed=[],
  ~produced=[],
  ~partitionHint=?,
  ~chapter=?,
): DSI.sliceShape => {
  sliceName,
  command,
  consumed,
  produced,
  partitionHint,
  ?chapter,
}

// The online-shop-hybrid catalog boundary, transcribed structurally (NO tag
// annotations — that is the point). AddProduct reads the category lifecycle.
let addProduct = slice(
  "AddProduct",
  ~command=[scal("productId"), scal("categoryId")],
  ~consumed=[
    ev("ProductAdded", [scal("productId")]),
    ev("CategoryAdded", [scal("categoryId")]),
    ev("CategoryArchived", [scal("categoryId")]),
  ],
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
    testSync(
      "scalar *Id uses the field name",
      () => expect(DSI.tagKeyOf(scal("categoryId")))->toBe("categoryId"),
    )
    testSync(
      "plural *Ids strips the trailing s",
      () => expect(DSI.tagKeyOf(arr("productIds")))->toBe("productId"),
    )
  })

  describe("hybrid catalog (no annotations)", () => {
    let d = DSI.infer(catalog)

    testSync(
      "derives categoryId as the only cross-partition key — without any @crossPartition",
      () => expect(d.crossPartitionTagKeys)->toEqual(["categoryId"]),
    )

    testSync(
      "AddProduct partition = productId (foreign categoryId eliminated)",
      () => expect(d.partitionBySlice->Dict.get("AddProduct"))->toEqual(Some("productId")),
    )

    testSync(
      "Category slices partition = categoryId",
      () => {
        expect(d.partitionBySlice->Dict.get("AddCategory"))->toEqual(Some("categoryId"))
        expect(d.partitionBySlice->Dict.get("RenameCategory"))->toEqual(Some("categoryId"))
        expect(d.partitionBySlice->Dict.get("ArchiveCategory"))->toEqual(Some("categoryId"))
      },
    )

    testSync(
      "ProductAdded indexes productId only — categoryId is payload (no sibling leak)",
      () => expect(d.tagKeysByEventType->Dict.get("ProductAdded"))->toEqual(Some(["productId"])),
    )

    testSync(
      "CategoryAdded indexes its own categoryId",
      () => expect(d.tagKeysByEventType->Dict.get("CategoryAdded"))->toEqual(Some(["categoryId"])),
    )

    testSync("no ambiguities for a well-formed boundary", () => expect(d.ambiguities)->toEqual([]))

    testSync(
      "ownerByKey points categoryId at a Category slice, productId at Product",
      () => {
        expect(d.ownerByKey->Dict.get("productId"))->toEqual(Some("AddProduct"))
        expect(d.ownerByKey->Dict.get("categoryId")->Option.isSome)->toBe(true)
      },
    )
  })

  describe("own composite read + @partitionTag hint (RecordProductDemand shape)", () => {
    // Event carries two owned-looking keys (productId, orderId); the slice reads
    // its OWN stream by both (idempotency). @partitionTag picks productId; orderId
    // must stay indexed because the slice reads its own event type by it.
    let recordDemand = slice(
      "RecordProductDemand",
      ~partitionHint="productId",
      ~consumed=[
        ev("ProductDemandRecorded", [scal("orderId")]),
        ev("ProductDemandRevoked", [scal("orderId")]),
      ],
      ~produced=[
        ev("ProductDemandRecorded", [scal("productId"), scal("orderId")]),
        ev("ProductDemandRevoked", [scal("productId"), scal("orderId")]),
      ],
    )
    let d = DSI.infer([recordDemand])

    testSync(
      "the @partitionTag hint resolves the partition (no ambiguity)",
      () => {
        expect(d.partitionBySlice->Dict.get("RecordProductDemand"))->toEqual(Some("productId"))
        expect(d.ambiguities)->toEqual([])
      },
    )
    testSync(
      "orderId stays indexed — it is an own-stream read key, not a foreign ref",
      () =>
        expect(d.tagKeysByEventType->Dict.get("ProductDemandRecorded"))->toEqual(
          Some(["orderId", "productId"]),
        ),
    )
    testSync(
      "orderId is not cross-partition (no Order entity owns it in this boundary)",
      () => expect(d.crossPartitionTagKeys)->toEqual([]),
    )
  })

  describe("array foreign reference (productIds) stays partition-scoped", () => {
    // PlaceOrder references products via an ARRAY (productIds). An array command
    // tag auto-fans into per-element single-tag clauses that read the foreign
    // entity's own partition (CatalogProductSynced is partitioned by productId),
    // so it must NOT be promoted to a cross-partition read — unlike a scalar
    // reference. This is the deliberate `PlaceOrder` counterexample.
    let placeOrder = slice(
      "PlaceOrder",
      ~command=[scal("orderId"), arr("productIds")],
      ~consumed=[
        ev("OrderPlaced", [scal("orderId")]),
        ev("CatalogProductSynced", [scal("productId")]),
      ],
      ~produced=[ev("OrderPlaced", [scal("orderId"), arr("productIds")])],
    )
    let productEntity = slice(
      "SyncCatalogProduct",
      ~command=[scal("productId")],
      ~consumed=[ev("CatalogProductSynced", [])],
      ~produced=[ev("CatalogProductSynced", [scal("productId")])],
    )
    let d = DSI.infer([placeOrder, productEntity])

    testSync(
      "an array-only foreign read is NOT cross-partition (auto-fans, partition-scoped)",
      () => expect(d.crossPartitionTagKeys)->toEqual([]),
    )
    testSync(
      "PlaceOrder partition = orderId",
      () => expect(d.partitionBySlice->Dict.get("PlaceOrder"))->toEqual(Some("orderId")),
    )
    testSync(
      "OrderPlaced indexes orderId only (productIds is a foreign payload ref)",
      () => expect(d.tagKeysByEventType->Dict.get("OrderPlaced"))->toEqual(Some(["orderId"])),
    )
  })

  // The schema adapter (DcbTag.eventShapesOfSchema / sliceShapeFromSchemas) is the
  // runtime's bridge from `S.t` to the pure boundary type. Exercise it on a REAL
  // annotated fixture schema and show inference reproduces the annotation-based
  // `extractCrossPartitionTagKeys` from the un-annotated structure.
  describe("schema adapter ⇄ inference parity", () => {
    let shapes = Reventless.DcbTag.eventShapesOfSchema(DcbFixtures.subscriptionEventSchema)

    testSync(
      "eventShapesOfSchema extracts *Id fields by name (tag flags ignored)",
      () => {
        expect(shapes->Array.length)->toBe(1)
        let arm = shapes->Array.getUnsafe(0)
        expect(arm.eventType)->toBe("StudentSubscribed")
        let names = arm.idFields->Array.map(f => f.name)->Array.toSorted(String.compare)
        expect(names)->toEqual(["courseId", "studentId"])
      },
    )

    testSync(
      "inference reproduces extractCrossPartitionTagKeys ⇒ [\"studentId\"]",
      () => {
        // A Student entity owns studentId; Subscribe (built from the real fixture
        // schema) reads it from the foreign StudentRegistered event.
        let studentEntity = slice(
          "RegisterStudent",
          ~produced=[ev("StudentRegistered", [scal("studentId")])],
        )
        let subscribe: DSI.sliceShape = {
          sliceName: "SubscribeStudent",
          // The real command carries studentId as a SCALAR — so the foreign read is
          // fanned cross-partition (a scalar reference, unlike PlaceOrder's array).
          command: [scal("courseId"), scal("studentId")],
          consumed: [ev("StudentRegistered", [scal("studentId")])],
          produced: shapes, // StudentSubscribed({courseId, studentId}) from the schema adapter
          partitionHint: None,
        }
        let d = DSI.infer([studentEntity, subscribe])
        expect(d.crossPartitionTagKeys)->toEqual(
          Reventless.DcbTag.extractCrossPartitionTagKeys(DcbFixtures.subscriptionEventSchema),
        )
        expect(d.partitionBySlice->Dict.get("SubscribeStudent"))->toEqual(Some("courseId"))
      },
    )
  })

  describe("validateScopeVsInference (annotation ⇄ inference)", () => {
    let d = DSI.infer(catalog)

    testSync(
      "flags @crossPartition on a slice's OWN partition as a contradiction",
      () => {
        // AddCategory's partition is categoryId; marking it @crossPartition is wrong.
        let issues = Reventless.DcbValidation.validateScopeVsInference(
          ~annotations=[("AddCategory", ["categoryId"])],
          ~inferred=d,
        )
        expect(issues.contradictions->Array.length)->toBe(1)
        expect((issues.contradictions->Array.getUnsafe(0)).sliceName)->toBe("AddCategory")
        expect(issues.redundancies)->toEqual([])
      },
    )

    testSync(
      "flags @crossPartition that inference already derives as redundant",
      () => {
        // AddProduct really does read categoryId cross-partition — the annotation is
        // just no longer needed.
        let issues = Reventless.DcbValidation.validateScopeVsInference(
          ~annotations=[("AddProduct", ["categoryId"])],
          ~inferred=d,
        )
        expect(issues.contradictions)->toEqual([])
        expect(issues.redundancies->Array.length)->toBe(1)
      },
    )

    testSync(
      "no annotations ⇒ no issues (the migrated catalog)",
      () => {
        let issues = Reventless.DcbValidation.validateScopeVsInference(
          ~annotations=catalog->Array.map(s => (s.sliceName, [])),
          ~inferred=d,
        )
        expect(issues.contradictions)->toEqual([])
        expect(issues.redundancies)->toEqual([])
      },
    )
  })

  describe("partition: identity given back only when subtraction leaves nothing", () => {
    let partitionOf = (d: DSI.derived, name) => d.partitionBySlice->Dict.get(name)

    testSync(
      "AddProduct without a hint stays productId, though its category arms come from a categoryId slice",
      () => {
        let d = DSI.infer(catalog)
        expect(addProduct.partitionHint)->toEqual(None)
        expect(d->partitionOf("AddProduct"))->toEqual(Some("productId"))
      },
    )

    testSync(
      "a lifecycle arm naming the slice's own id resolves",
      () => {
        let changeName = slice(
          "ChangeProductName",
          ~command=[scal("productId")],
          ~consumed=[ev("ProductAdded", [scal("productId")])],
          ~produced=[ev("ProductNameChanged", [scal("productId")])],
        )
        let d = DSI.infer(catalog->Array.concat([changeName]))
        expect(d->partitionOf("ChangeProductName"))->toEqual(Some("productId"))
        expect(d.ambiguities)->toEqual([])
      },
    )

    // Every arm a slice reads from the other also names that slice's ids, so
    // subtraction leaves both with nothing and each depends on the other.
    let placeOrder = slice(
      "PlaceOrder",
      ~partitionHint="orderId",
      ~command=[scal("orderId"), scal("customerId")],
      ~produced=[ev("OrderPlaced", [scal("orderId"), scal("customerId"), arr("productIds")])],
    )
    let shipOrder = slice(
      "ShipOrder",
      ~command=[scal("orderId")],
      ~consumed=[
        ev("OrderPlaced", [scal("orderId"), scal("customerId"), arr("productIds")]),
        ev("OrderCancelled", [scal("orderId"), arr("productIds")]),
      ],
      ~produced=[ev("OrderShipped", [scal("orderId"), scal("customerId")])],
    )
    let cancelOrder = slice(
      "CancelOrder",
      ~command=[scal("orderId")],
      ~consumed=[
        ev("OrderPlaced", [scal("orderId"), scal("customerId"), arr("productIds")]),
        ev("OrderShipped", [scal("orderId"), scal("customerId")]),
      ],
      ~produced=[ev("OrderCancelled", [scal("orderId"), arr("productIds")])],
    )

    testSync(
      "the ShipOrder ⇄ CancelOrder cycle resolves both to orderId",
      () => {
        let d = DSI.infer([placeOrder, shipOrder, cancelOrder])
        expect(d->partitionOf("ShipOrder"))->toEqual(Some("orderId"))
        expect(d->partitionOf("CancelOrder"))->toEqual(Some("orderId"))
        expect(d.ambiguities)->toEqual([])
      },
    )

    testSync(
      "seen alone, the same slice names the arms to change",
      () =>
        expect(DSI.partitionBlockers(cancelOrder))->toEqual([
          ("orderId", ["OrderPlaced", "OrderShipped"]),
          ("productId", ["OrderPlaced"]),
        ]),
    )

    let recordDemand = slice(
      "RecordProductDemand",
      ~command=[scal("productId"), scal("orderId")],
      ~consumed=[ev("ProductDemandRecorded", [scal("orderId")])],
      ~produced=[ev("ProductDemandRecorded", [scal("productId"), scal("orderId")])],
    )

    testSync(
      "a join without a hint stays ambiguous",
      () => {
        let d = DSI.infer([recordDemand])
        expect(d->partitionOf("RecordProductDemand"))->toEqual(None)
        expect(d.ambiguities->Array.map(((n, _)) => n))->toEqual(["RecordProductDemand"])
      },
    )

    testSync(
      "a produced id another slice is partitioned by is not dropped",
      () => {
        // Were productId dropped for belonging to AddProduct, the join would
        // silently resolve to orderId.
        let d = DSI.infer(catalog->Array.concat([placeOrder, recordDemand]))
        expect(d->partitionOf("RecordProductDemand"))->toEqual(None)
        expect(
          d.ambiguities->Array.some(
            ((n, reason)) =>
              n == "RecordProductDemand" && reason->String.includes("orderId, productId"),
          ),
        )->toBe(true)
      },
    )

    testSync(
      "a boundary that never settles is reported, not guessed",
      () => {
        // A resolves only while B is unresolved, and B only while A is: each
        // pass flips both. Z* arms have no producer, so they always block.
        let a = slice(
          "A",
          ~consumed=[ev("BHappened", [scal("xId")]), ev("ZHappened", [scal("yId")])],
          ~produced=[ev("AHappened", [scal("xId"), scal("yId")])],
        )
        let b = slice(
          "B",
          ~consumed=[ev("AHappened", [scal("yId")]), ev("Z2Happened", [scal("xId")])],
          ~produced=[ev("BHappened", [scal("xId"), scal("yId")])],
        )
        let d = DSI.infer([a, b])
        expect(d.ambiguities->Array.map(((n, _)) => n))->toEqual(["A", "B"])
        expect(
          d.ambiguities->Array.every(((_, reason)) => reason->String.includes("did not settle")),
        )->toBe(true)
      },
    )
  })

  describe("partition: the chapter breaks a tie", () => {
    let placeOrder = (~chapter=?) =>
      slice(
        "PlaceOrder",
        ~command=[scal("orderId"), scal("customerId")],
        ~consumed=[ev("OrderPlaced", [scal("orderId")])],
        ~produced=[ev("OrderPlaced", [scal("orderId"), scal("customerId")])],
        ~chapter?,
      )
    let cancelOrder = slice(
      "CancelOrder",
      ~chapter="Order",
      ~consumed=[ev("OrderPlaced", [])],
      ~produced=[ev("OrderCancelled", [scal("orderId")])],
    )
    let partitionOf = (d: DSI.derived, name) => d.partitionBySlice->Dict.get(name)

    testSync(
      "an order and its customer resolve to the id every Order event carries",
      () => {
        let d = DSI.infer([placeOrder(~chapter="Order"), cancelOrder])
        expect(d->partitionOf("PlaceOrder"))->toEqual(Some("orderId"))
        expect(d.ambiguities)->toEqual([])
      },
    )

    testSync(
      "without a chapter the same slice stays ambiguous",
      () => {
        let d = DSI.infer([placeOrder(), cancelOrder])
        expect(d->partitionOf("PlaceOrder"))->toEqual(None)
      },
    )

    testSync(
      "a join whose chapter carries both ids stays ambiguous, and the reason says so",
      () => {
        let demand = slice(
          "RecordProductDemand",
          ~chapter="ProductDemand",
          ~produced=[ev("ProductDemandRecorded", [scal("productId"), scal("orderId")])],
        )
        let d = DSI.infer([demand])
        expect(d->partitionOf("RecordProductDemand"))->toEqual(None)
        expect(
          d.ambiguities->Array.some(
            ((_, reason)) => reason->String.includes("The ProductDemand chapter does not decide"),
          ),
        )->toBe(true)
      },
    )

    testSync(
      "it never overrides a key the subtraction decided",
      () => {
        // AddProduct filed under a chapter keyed by categoryId still resolves to
        // productId: the tie-breaker only sees slices left with several keys.
        let misfiled = {...addProduct, chapter: "Category"}
        let d = DSI.infer([misfiled, {...addCategory, chapter: "Category"}])
        expect(d->partitionOf("AddProduct"))->toEqual(Some("productId"))
      },
    )
  })

  describe("validatePartitionHintsVsInference (@partitionTag ⇄ inference)", () => {
    let hinted = (s: DSI.sliceShape, key) => {...s, partitionHint: Some(key)}
    let check = shapes => Reventless.DcbValidation.validatePartitionHintsVsInference(~shapes)
    let names = (issues: array<Reventless.DcbValidation.validationError>) =>
      issues->Array.map(e => e.sliceName)
    let refusals = (issues: array<Reventless.DcbValidation.validationError>) =>
      issues->Array.map(e => e.refusal)

    testSync(
      "a hint naming a key the slice only references is a contradiction",
      () => {
        let issues = check([hinted(addProduct, "categoryId"), addCategory])
        expect(issues.contradictions->refusals)->toEqual([
          Some(
            Reventless.StartRefusal.PartitionContradiction({
              slice: "AddProduct",
              named: "categoryId",
              inference: Derives("productId"),
              arms: [],
            }),
          ),
        ])
        expect(issues.redundancies)->toEqual([])
      },
    )

    testSync(
      "a hint inference reaches unaided is redundant",
      () => {
        let issues = check([hinted(addProduct, "productId"), addCategory])
        expect(issues.contradictions)->toEqual([])
        expect(issues.redundancies->names)->toEqual(["AddProduct"])
      },
    )

    testSync(
      "a hint that decides a join is neither",
      () => {
        let demand = slice(
          "RecordProductDemand",
          ~partitionHint="productId",
          ~produced=[ev("ProductDemandRecorded", [scal("productId"), scal("orderId")])],
        )
        let issues = check([demand])
        expect(issues.contradictions)->toEqual([])
        expect(issues.redundancies)->toEqual([])
      },
    )

    // `ShipOrder` records the carrier's booking, which nothing else in the boundary
    // writes or reads. Rule 1 subtracts `orderId` (read off `OrderPlaced`) and is
    // left with the booking: `AddProduct`'s shape exactly, with the other answer.
    let placeOrder = slice(
      "PlaceOrder",
      ~chapter="Order",
      ~produced=[ev("OrderPlaced", [scal("orderId")])],
    )
    let shipOrder = slice(
      "ShipOrder",
      ~chapter="Order",
      ~partitionHint="orderId",
      ~command=[scal("orderId"), scal("carrierBookingId")],
      ~consumed=[ev("OrderPlaced", [scal("orderId")]), ev("OrderShipped", [scal("orderId")])],
      ~produced=[ev("OrderShipped", [scal("orderId"), scal("carrierBookingId")])],
    )

    testSync(
      "a hint its chapter backs overrides inference instead of contradicting it",
      () => {
        let issues = check([placeOrder, shipOrder])
        expect(issues.contradictions)->toEqual([])
        expect(issues.redundancies)->toEqual([])
        expect(issues.overrides->names)->toEqual(["ShipOrder"])
        // and the hint is what the boundary is partitioned by
        expect(
          DSI.resolvePartitions([placeOrder, shipOrder]).partitionBySlice->Dict.get("ShipOrder"),
        )->toEqual(Some("orderId"))
      },
    )

    testSync(
      "without a chapter the same hint is still a contradiction",
      () => {
        let noChapter = (s: DSI.sliceShape) => {...s, chapter: ?None}
        let issues = check([noChapter(placeOrder), noChapter(shipOrder)])
        expect(issues.contradictions->names)->toEqual(["ShipOrder"])
        expect(issues.overrides)->toEqual([])
      },
    )

    // Every producer is present, so the arms it reads by `categoryId` all come from
    // category slices: only the chapter can refuse the hint.
    let categories = [
      {...addCategory, chapter: "Category"},
      {...renameCategory, chapter: "Category"},
      {...archiveCategory, chapter: "Category"},
    ]

    testSync(
      "a hint its chapter disagrees with is still a contradiction",
      () => {
        // `RenameProduct` writes only `productId`, so `Product/` is about products.
        let renameProduct = slice(
          "RenameProduct",
          ~chapter="Product",
          ~consumed=[ev("ProductAdded", [scal("productId")])],
          ~produced=[ev("ProductRenamed", [scal("productId")])],
        )
        let inProduct = {...hinted(addProduct, "categoryId"), chapter: "Product"}
        let issues = check([inProduct, renameProduct, ...categories])
        expect(issues.contradictions->names)->toEqual(["AddProduct"])
        expect(issues.overrides)->toEqual([])
      },
    )

    testSync(
      "a chapter that carries both keys everywhere backs neither",
      () => {
        // One slice, one event with both ids: the chapter cannot say which one it is about.
        let inProduct = {...hinted(addProduct, "categoryId"), chapter: "Product"}
        let issues = check([inProduct, ...categories])
        expect(issues.contradictions->names)->toEqual(["AddProduct"])
        expect(issues.overrides)->toEqual([])
      },
    )

    testSync(
      "a chapter-backed hint read off another entity's events is still a contradiction",
      () => {
        // `WarehouseAssigned` carries the order but belongs to the warehouse.
        let assign = slice(
          "AssignWarehouse",
          ~chapter="Warehouse",
          ~partitionHint="warehouseId",
          ~produced=[ev("WarehouseAssigned", [scal("warehouseId"), scal("orderId")])],
        )
        let ship = {
          ...shipOrder,
          consumed: shipOrder.consumed->Array.concat([
            ev("WarehouseAssigned", [scal("warehouseId"), scal("orderId")]),
          ]),
        }
        let issues = check([placeOrder, ship, assign])
        expect(issues.overrides->names)->toEqual([])
        expect(issues.contradictions->refusals)->toEqual([
          Some(
            Reventless.StartRefusal.PartitionContradiction({
              slice: "ShipOrder",
              named: "orderId",
              inference: Derives("carrierBookingId"),
              arms: ["WarehouseAssigned"],
            }),
          ),
        ])
        expect(DSI.infer([placeOrder, ship, assign]).crossPartitionPairs)->toEqual([])
      },
    )

    testSync(
      "marked @crossPartition, the same read is an override with one pair",
      () => {
        let assign = slice(
          "AssignWarehouse",
          ~chapter="Warehouse",
          ~partitionHint="warehouseId",
          ~produced=[ev("WarehouseAssigned", [scal("warehouseId"), scal("orderId")])],
        )
        let ship = {
          ...shipOrder,
          consumed: shipOrder.consumed->Array.concat([
            ev("WarehouseAssigned", [scal("warehouseId"), cross("orderId")]),
          ]),
        }
        let boundary = [placeOrder, ship, assign]
        let issues = check(boundary)
        expect(issues.contradictions)->toEqual([])
        expect(issues.overrides->names)->toEqual(["ShipOrder"])
        let d = DSI.infer(boundary)
        expect(d.crossPartitionPairs)->toEqual([
          {
            DSI.reader: "ShipOrder",
            eventType: "WarehouseAssigned",
            key: "orderId",
            writers: ["AssignWarehouse"],
          },
        ])
        // the pair reads the reader's own key: no key turns cross-partition
        expect(d.crossPartitionTagKeys)->toEqual([])
      },
    )

    // A question's answer is kept per message. `AnswerMarked` names the reply, but
    // `QuestionReopened` does not, so the reply cannot be the partition — though
    // `ReplyPosted` comes from a slice partitioned by it, which once gave it back.
    let postMessage = slice(
      "PostMessage",
      ~chapter="Messages",
      ~produced=[ev("MessagePosted", [scal("messageId"), scal("channelId")])],
      ~partitionHint="messageId",
    )
    let postReply = slice(
      "PostReply",
      ~chapter="Messages",
      ~consumed=[ev("MessagePosted", [scal("messageId"), scal("channelId")])],
      ~produced=[ev("ReplyPosted", [scal("replyId"), scal("messageId"), scal("channelId")])],
    )
    let questionState = slice(
      "QuestionState",
      ~chapter="Questions",
      ~partitionHint="messageId",
      ~consumed=[
        ev("AnswerMarked", [scal("messageId"), scal("replyId"), scal("channelId")]),
        ev("QuestionReopened", [scal("messageId"), scal("channelId")]),
        ev("MessagePosted", [scal("messageId"), scal("channelId")]),
        ev("ReplyPosted", [scal("replyId"), scal("messageId"), scal("channelId")]),
      ],
      ~produced=[
        ev("AnswerMarked", [scal("messageId"), scal("replyId"), scal("channelId")]),
        ev("QuestionReopened", [scal("messageId"), scal("channelId")]),
      ],
    )
    let questions = [postMessage, postReply, questionState]

    testSync(
      "inference never picks a key one of the slice's own events lacks",
      () => {
        let unhinted = {...questionState, partitionHint: None}
        let r = DSI.resolvePartitions([postMessage, postReply, unhinted])
        expect(r.partitionBySlice->Dict.get("QuestionState"))->toEqual(None)
        expect(r.candidatesBySlice->Dict.get("QuestionState"))->toEqual(Some([]))
      },
    )

    testSync(
      "a hint deciding a slice inference leaves unresolved is accepted",
      () => {
        // `ReplyPosted`'s writer is outside the boundary: where it is stored is not known here.
        let boundary = [postMessage, questionState]
        let issues = check(boundary)
        expect(issues.contradictions)->toEqual([])
        expect(issues.redundancies)->toEqual([])
        expect(
          DSI.resolvePartitions(boundary).partitionBySlice->Dict.get("QuestionState"),
        )->toEqual(Some("messageId"))
      },
    )

    testSync(
      "a hint deciding an unresolved slice is refused when its read misses events stored elsewhere",
      () => {
        // `ReplyPosted` is stored under the reply, so a read by messageId never finds it.
        let issues = check(questions)
        expect(issues.contradictions->refusals)->toEqual([
          Some(
            Reventless.StartRefusal.PartitionUnreachable({
              slice: "QuestionState",
              named: "messageId",
              missed: ["ReplyPosted"],
            }),
          ),
        ])
      },
    )

    let markedReplies = {
      ...questionState,
      consumed: questionState.consumed->Array.map(
        e =>
          e.eventType == "ReplyPosted"
            ? ev("ReplyPosted", [scal("replyId"), cross("messageId"), scal("channelId")])
            : e,
      ),
    }

    testSync(
      "marked @crossPartition, the question reads its replies as a pair",
      () => {
        let boundary = [postMessage, postReply, markedReplies]
        let issues = check(boundary)
        expect(issues.contradictions)->toEqual([])
        let d = DSI.infer(boundary)
        expect(d.crossPartitionPairs)->toEqual([
          {
            DSI.reader: "QuestionState",
            eventType: "ReplyPosted",
            key: "messageId",
            writers: ["PostReply"],
          },
        ])
        expect(d.crossPartitionTagKeys)->toEqual([])
        let arms = Reventless.DcbValidation.validateCrossPartitionArms(
          ~shapes=boundary,
          ~inferred=d,
        )
        expect(arms.contradictions)->toEqual([])
        expect(arms.redundancies)->toEqual([])
      },
    )

    testSync(
      "a marker on a key that is not the slice's own is refused",
      () => {
        let byChannel = {
          ...questionState,
          consumed: questionState.consumed->Array.map(
            e =>
              e.eventType == "ReplyPosted"
                ? ev("ReplyPosted", [scal("replyId"), cross("messageId"), cross("channelId")])
                : e,
          ),
        }
        let boundary = [postMessage, postReply, byChannel]
        let arms = Reventless.DcbValidation.validateCrossPartitionArms(
          ~shapes=boundary,
          ~inferred=DSI.infer(boundary),
        )
        expect(arms.contradictions->refusals)->toEqual([
          Some(
            Reventless.StartRefusal.ScopeContradiction({
              slice: "QuestionState",
              eventType: "ReplyPosted",
              marked: "channelId",
              partition: "messageId",
            }),
          ),
        ])
      },
    )

    testSync(
      "a marker on an event already stored under the slice's key is redundant",
      () => {
        let markedMessage = {
          ...markedReplies,
          consumed: markedReplies.consumed->Array.map(
            e =>
              e.eventType == "MessagePosted"
                ? ev("MessagePosted", [cross("messageId"), scal("channelId")])
                : e,
          ),
        }
        let boundary = [postMessage, postReply, markedMessage]
        let d = DSI.infer(boundary)
        let arms = Reventless.DcbValidation.validateCrossPartitionArms(
          ~shapes=boundary,
          ~inferred=d,
        )
        expect(arms.contradictions)->toEqual([])
        expect(arms.redundancies->names)->toEqual(["QuestionState"])
        // and it makes no pair
        expect(d.crossPartitionPairs->Array.map(p => p.eventType))->toEqual(["ReplyPosted"])
      },
    )

    testSync(
      "a hint naming a key one of the slice's events lacks is still a contradiction",
      () => {
        let issues = check([
          postMessage,
          postReply,
          {...questionState, partitionHint: Some("replyId")},
        ])
        expect(issues.contradictions->names)->toEqual(["QuestionState"])
      },
    )
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

    testSync(
      "a pure-join slice with no own key is reported ambiguous",
      () => {
        let names = d.ambiguities->Array.map(((n, _)) => n)
        expect(names->Array.includes("Join"))->toBe(true)
      },
    )
    testSync(
      "the well-formed owners are not ambiguous",
      () => {
        let names = d.ambiguities->Array.map(((n, _)) => n)
        expect(names->Array.includes("A"))->toBe(false)
        expect(names->Array.includes("B"))->toBe(false)
      },
    )
  })
})
