open JestGlobals

let getProperty = (schema: JSON.t, key: string): option<JSON.t> =>
  switch schema->JSON.Decode.object {
  | Some(obj) => obj->Dict.get(key)
  | None => None
  }

let getPropertyOf = (schema: JSON.t, fieldName: string): option<JSON.t> =>
  switch getProperty(schema, "properties") {
  | Some(props) =>
    switch props->JSON.Decode.object {
    | Some(obj) => obj->Dict.get(fieldName)
    | None => None
    }
  | None => None
  }

let emptySpec: Reventless.StateAnnotations.stateAnnotationSpec = {
  ids: [],
  compositeIds: [],
  subIds: [],
  compositeSubIds: [],
  indexes: [],
  hidden: [],
  summary: [],
  drillTargets: [],
  drillTargetKeys: [],
  collapsed: [],
  scan: [],
  scanSort: [],
  semantic: [],
  metric: [],
  status: None,
  groupBy: None,
  visibility: None,
}

describe("SuryToJsonSchema:", () => {
  describe("deriveObjectSchema with no annotations:", () => {
    testSync("emits plain JSON Schema when no metadata is attached", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "name": s.matches(S.string),
        }
      )->S.castToUnknown
      let json = SuryToJsonSchema.deriveObjectSchema(schema)
      let idSchema = getPropertyOf(json, "id")
      expect(
        idSchema->Option.flatMap(s => getProperty(s, "x-reventless-id")),
      )->toBe(None)
    })

    testSync("emits format:\"date-time\" for a DateTime-marked string field", () => {
      let schema = S.schema(s =>
        {
          "placedAt": s.matches(Reventless.DateTime.string),
          "name": s.matches(S.string),
        }
      )->S.castToUnknown
      let json = SuryToJsonSchema.deriveObjectSchema(schema)
      expect(
        getPropertyOf(json, "placedAt")
        ->Option.flatMap(s => getProperty(s, "format"))
        ->Option.flatMap(JSON.Decode.string),
      )->toBe(Some("date-time"))
      // A plain string field stays plain — the marker is opt-in.
      expect(
        getPropertyOf(json, "name")->Option.flatMap(s => getProperty(s, "format")),
      )->toBe(None)
    })
  })

  describe("deriveObjectSchema with stateAnnotations metadata:", () => {
    let withSpec = (schema, spec) =>
      schema->S.Metadata.set(~id=Reventless.StateAnnotations.stateAnnotationsId, spec)

    testSync("emits x-reventless-id on field listed in ids", () => {
      let schema = S.schema(s =>
        {
          "entityId": s.matches(S.string),
          "name": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, ids: ["entityId"]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let entityIdSchema = getPropertyOf(json, "entityId")
      expect(
        entityIdSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-id"))
        ->Option.flatMap(JSON.Decode.bool),
      )->toBe(Some(true))
    })

    testSync("emits x-reventless-compositeId on each compositeId field", () => {
      let schema = S.schema(s =>
        {
          "environment": s.matches(S.string),
          "platformName": s.matches(S.string),
          "name": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({
        ...emptySpec,
        compositeIds: ["environment", "platformName"],
      })
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let envSchema = getPropertyOf(json, "environment")
      let platformSchema = getPropertyOf(json, "platformName")
      expect((
        envSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-compositeId"))
        ->Option.flatMap(JSON.Decode.bool),
        platformSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-compositeId"))
        ->Option.flatMap(JSON.Decode.bool),
      ))->toEqual((Some(true), Some(true)))
    })

    testSync("emits x-reventless-subId on field listed in subIds", () => {
      let schema = S.schema(s =>
        {
          "itemId": s.matches(S.string),
          "version": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, subIds: ["version"]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let versionSchema = getPropertyOf(json, "version")
      expect(
        versionSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-subId"))
        ->Option.flatMap(JSON.Decode.bool),
      )->toBe(Some(true))
    })

    testSync("emits x-reventless-index as the index name when named", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "ownerId": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({
        ...emptySpec,
        indexes: [("ownerId", "byOwner")],
      })
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let ownerIdSchema = getPropertyOf(json, "ownerId")
      expect(
        ownerIdSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-index"))
        ->Option.flatMap(JSON.Decode.string),
      )->toBe(Some("byOwner"))
    })

    testSync("emits x-reventless-index as true for unnamed @index", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "category": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({
        ...emptySpec,
        indexes: [("category", "")],
      })
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let categorySchema = getPropertyOf(json, "category")
      expect(
        categorySchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-index"))
        ->Option.flatMap(JSON.Decode.bool),
      )->toBe(Some(true))
    })

    testSync("does not emit x-reventless-* on unannotated fields", () => {
      let schema = S.schema(s =>
        {
          "entityId": s.matches(S.string),
          "name": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, ids: ["entityId"]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let nameSchema = getPropertyOf(json, "name")
      expect(
        nameSchema->Option.flatMap(s => getProperty(s, "x-reventless-id")),
      )->toBe(None)
    })

    testSync("emits x-reventless-hidden on field listed in hidden", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "deploymentId": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, hidden: ["deploymentId"]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let deploymentIdSchema = getPropertyOf(json, "deploymentId")
      let idSchema = getPropertyOf(json, "id")
      expect((
        deploymentIdSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-hidden"))
        ->Option.flatMap(JSON.Decode.bool),
        idSchema->Option.flatMap(s => getProperty(s, "x-reventless-hidden")),
      ))->toEqual((Some(true), None))
    })

    testSync("emits x-reventless-summary on field listed in summary", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "pluginName": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, summary: ["pluginName"]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let pluginNameSchema = getPropertyOf(json, "pluginName")
      let idSchema = getPropertyOf(json, "id")
      expect((
        pluginNameSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-summary"))
        ->Option.flatMap(JSON.Decode.bool),
        idSchema->Option.flatMap(s => getProperty(s, "x-reventless-summary")),
      ))->toEqual((Some(true), None))
    })

    testSync("emits x-reventless-drillTarget as the slice name", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "components": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({
        ...emptySpec,
        drillTargets: [("components", "ResourceInventory")],
      })
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let componentsSchema = getPropertyOf(json, "components")
      let idSchema = getPropertyOf(json, "id")
      expect((
        componentsSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-drillTarget"))
        ->Option.flatMap(JSON.Decode.string),
        idSchema->Option.flatMap(s => getProperty(s, "x-reventless-drillTarget")),
      ))->toEqual((Some("ResourceInventory"), None))
    })

    testSync("emits x-reventless-drillTargetKey as the key path", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "components": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({
        ...emptySpec,
        drillTargets: [("components", "ResourceInventory")],
        drillTargetKeys: [("components", "kind/name")],
      })
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let componentsSchema = getPropertyOf(json, "components")
      expect(
        componentsSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-drillTargetKey"))
        ->Option.flatMap(JSON.Decode.string),
      )->toBe(Some("kind/name"))
    })

    testSync("does not emit x-reventless-drillTargetKey when no key was supplied", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "components": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({
        ...emptySpec,
        drillTargets: [("components", "ResourceInventory")],
      })
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let componentsSchema = getPropertyOf(json, "components")
      expect(
        componentsSchema->Option.flatMap(s => getProperty(s, "x-reventless-drillTargetKey")),
      )->toBe(None)
    })

    testSync("emits x-reventless-scan on field listed in scan", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "status": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, scan: ["status"]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let statusSchema = getPropertyOf(json, "status")
      let idSchema = getPropertyOf(json, "id")
      expect((
        statusSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-scan"))
        ->Option.flatMap(JSON.Decode.bool),
        idSchema->Option.flatMap(s => getProperty(s, "x-reventless-scan")),
      ))->toEqual((Some(true), None))
    })

    testSync("emits x-reventless-scanSort on field listed in scanSort", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "name": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, scanSort: ["name"]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let nameSchema = getPropertyOf(json, "name")
      let idSchema = getPropertyOf(json, "id")
      expect((
        nameSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-scanSort"))
        ->Option.flatMap(JSON.Decode.bool),
        idSchema->Option.flatMap(s => getProperty(s, "x-reventless-scanSort")),
      ))->toEqual((Some(true), None))
    })

    testSync("emits x-reventless-semantic on the field listed in semantic", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "total": s.matches(S.float),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, semantic: [("total", "currency")]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let totalSchema = getPropertyOf(json, "total")
      let idSchema = getPropertyOf(json, "id")
      expect((
        totalSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-semantic"))
        ->Option.flatMap(JSON.Decode.string),
        idSchema->Option.flatMap(s => getProperty(s, "x-reventless-semantic")),
      ))->toEqual((Some("currency"), None))
    })

    testSync("emits x-reventless-metric {aggregate,label} on the field listed in metric", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "total": s.matches(S.float),
        }
      )->S.castToUnknown
      let schema' =
        schema->withSpec({...emptySpec, metric: [("total", {aggregate: "sum", label: "Revenue"})]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let metricObj = getPropertyOf(json, "total")->Option.flatMap(s => getProperty(s, "x-reventless-metric"))
      expect((
        metricObj->Option.flatMap(m => getProperty(m, "aggregate"))->Option.flatMap(JSON.Decode.string),
        metricObj->Option.flatMap(m => getProperty(m, "label"))->Option.flatMap(JSON.Decode.string),
      ))->toEqual((Some("sum"), Some("Revenue")))
    })

    testSync("omits the metric label when empty (UI derives one from the field name)", () => {
      let schema = S.schema(s => {"total": s.matches(S.float)})->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, metric: [("total", {aggregate: "sum", label: ""})]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let metricObj = getPropertyOf(json, "total")->Option.flatMap(s => getProperty(s, "x-reventless-metric"))
      expect((
        metricObj->Option.flatMap(m => getProperty(m, "aggregate"))->Option.flatMap(JSON.Decode.string),
        metricObj->Option.flatMap(m => getProperty(m, "label")),
      ))->toEqual((Some("sum"), None))
    })

    testSync("emits x-reventless-group-by on the field named by groupBy", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "kind": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, groupBy: Some("kind")})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let kindSchema = getPropertyOf(json, "kind")
      let idSchema = getPropertyOf(json, "id")
      expect((
        kindSchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-group-by"))
        ->Option.flatMap(JSON.Decode.bool),
        idSchema->Option.flatMap(s => getProperty(s, "x-reventless-group-by")),
      ))->toEqual((Some(true), None))
    })

    testSync("emits x-reventless-collapsed on field listed in collapsed", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "primaryResource": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, collapsed: ["primaryResource"]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let primarySchema = getPropertyOf(json, "primaryResource")
      let idSchema = getPropertyOf(json, "id")
      expect((
        primarySchema
        ->Option.flatMap(s => getProperty(s, "x-reventless-collapsed"))
        ->Option.flatMap(JSON.Decode.bool),
        idSchema->Option.flatMap(s => getProperty(s, "x-reventless-collapsed")),
      ))->toEqual((Some(true), None))
    })

    testSync("emits x-reventless-visibility at top level when visibility is Internal", () => {
      let schema = S.schema(s => {"id": s.matches(S.string)})->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, visibility: Some("Internal")})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      expect(
        getProperty(json, "x-reventless-visibility")->Option.flatMap(JSON.Decode.string),
      )->toBe(Some("Internal"))
    })

    testSync("omits x-reventless-visibility when visibility is None (default Public)", () => {
      let schema = S.schema(s => {"id": s.matches(S.string)})->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, visibility: None})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      expect(getProperty(json, "x-reventless-visibility"))->toBe(None)
    })
  })

  // Parity sanity-check: deriveObjectSchema and the legacy S.toJSONSchema must
  // agree on `properties` keyset and `required` array for unannotated objects,
  // so swapping the encoder at Plugin_Structure.res:261/280 doesn't drop fields.
  describe("parity with S.toJSONSchema for unannotated objects:", () => {
    let getKeys = (schema: JSON.t): array<string> =>
      switch getProperty(schema, "properties")->Option.flatMap(JSON.Decode.object) {
      | Some(obj) => obj->Dict.keysToArray
      | None => []
      }

    let getRequired = (schema: JSON.t): array<string> =>
      switch getProperty(schema, "required")->Option.flatMap(JSON.Decode.array) {
      | Some(arr) => arr->Array.filterMap(JSON.Decode.string)
      | None => []
      }

    let sortStrings = (xs: array<string>): array<string> =>
      xs->Array.toSorted(String.compare)

    testSync("properties keyset matches between deriveObjectSchema and S.toJSONSchema", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "name": s.matches(S.string),
          "count": s.matches(S.int),
        }
      )->S.castToUnknown
      let derived = SuryToJsonSchema.deriveObjectSchema(schema)
      let native = (schema->S.toJSONSchema->Obj.magic: JSON.t)
      expect(derived->getKeys->sortStrings)->toEqual(native->getKeys->sortStrings)
    })

    testSync("required array matches between deriveObjectSchema and S.toJSONSchema", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "name": s.matches(S.string),
        }
      )->S.castToUnknown
      let derived = SuryToJsonSchema.deriveObjectSchema(schema)
      let native = (schema->S.toJSONSchema->Obj.magic: JSON.t)
      expect(derived->getRequired->sortStrings)->toEqual(native->getRequired->sortStrings)
    })

    testSync("S.toJSONSchema does NOT emit x-reventless-* keys even when metadata is set", () => {
      let withSpec = (schema, spec) =>
        schema->S.Metadata.set(~id=Reventless.StateAnnotations.stateAnnotationsId, spec)
      let schema = S.schema(s =>
        {
          "entityId": s.matches(S.string),
          "name": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, ids: ["entityId"]})
      let native = (schema'->S.toJSONSchema->Obj.magic: JSON.t)
      let entityIdSchema = getPropertyOf(native, "entityId")
      expect(
        entityIdSchema->Option.flatMap(s => getProperty(s, "x-reventless-id")),
      )->toBe(None)
    })
  })

  // Reference-ness and DCB-tagged-ness are separate facts that happen to
  // co-occur on `Reference.to_`. The schema walk tests them independently, and
  // must keep doing so: a field can carry either alone, and a semantic type that
  // is marked but deliberately *not* DCB-tagged (a storage ref, say) must not be
  // dragged into entity-id classification by the other fact. Routing failures do
  // not show up in a schema diff, so the distinction is pinned here executably.
  describe("reference / DCB-tag decoupling:", () => {
    let formatOf = (schema: JSON.t, fieldName: string): option<JSON.t> =>
      getPropertyOf(schema, fieldName)->Option.flatMap(s => getProperty(s, "format"))

    testSync("a DCB-tagged field with no reference is still an entity id", () => {
      let schema = S.schema(s =>
        {
          "orderId": s.matches(Reventless.DcbTag.string),
        }
      )->S.castToUnknown
      let json = SuryToJsonSchema.deriveObjectSchema(schema)
      expect(formatOf(json, "orderId"))->toEqual(Some(JSON.Encode.string("uuid")))
      expect(Reventless.Reference.getTarget(schema))->toBe(None)
    })

    testSync("a reference without a DCB tag is still an entity id", () => {
      let field = Reventless.Reference.toWithoutDcbTag("Customer")
      let schema = S.schema(s => {"customerId": s.matches(field)})->S.castToUnknown
      let json = SuryToJsonSchema.deriveObjectSchema(schema)
      expect(formatOf(json, "customerId"))->toEqual(Some(JSON.Encode.string("uuid")))
      expect(Reventless.DcbTag.isTagged(field->S.castToUnknown))->toBe(false)
    })

    testSync("Reference.to_ carries both facts", () => {
      let field = Reventless.Reference.to_("Customer")
      expect(Reventless.DcbTag.isTagged(field->S.castToUnknown))->toBe(true)
      expect(
        Reventless.Reference.getTarget(field->S.castToUnknown)->Option.map(t => t.entity),
      )->toEqual(Some("Customer"))
    })

    testSync("neither reference nor tag emits x-reventless-semantic on the wire", () => {
      // `dateTime` and `reference` predate the generic marker and keep emitting
      // `format`; adding the semantic key for them would change a published
      // contract. Only semantics without a dedicated shape surface as the key.
      let schema = S.schema(s =>
        {
          "customerId": s.matches(Reventless.Reference.to_("Customer")),
          "placedAt": s.matches(Reventless.DateTime.string),
        }
      )->S.castToUnknown
      let json = SuryToJsonSchema.deriveObjectSchema(schema)
      let semanticOf = fieldName =>
        getPropertyOf(json, fieldName)->Option.flatMap(s =>
          getProperty(s, "x-reventless-semantic")
        )
      expect(semanticOf("customerId"))->toBe(None)
      expect(semanticOf("placedAt"))->toBe(None)
    })
  })

  // The reason the generic marker exists. `x-reventless-semantic` used to be
  // emitted only by the annotation merge, which is fed by a PPX pass that only
  // ever runs on read-model `state` records — so a command field could not carry
  // a semantic at all. This walk is shape-driven and runs over every schema, so
  // the declaration reaches the place the value is first accepted.
  describe("type-carried semantics on a command field:", () => {
    let semanticOf = (json, fieldName) =>
      getPropertyOf(json, fieldName)->Option.flatMap(s => getProperty(s, "x-reventless-semantic"))

    testSync("a storage-ref command field emits the semantic id", () => {
      let schema = S.schema(s =>
        {
          "productId": s.matches(S.string),
          "imageUrl": s.matches(Reventless.StorageRef.forStore(~store="productImages")),
        }
      )->S.castToUnknown
      let json = SuryToJsonSchema.deriveObjectSchema(schema)
      expect(semanticOf(json, "imageUrl"))->toEqual(Some(JSON.Encode.string("storageRef")))
      expect(semanticOf(json, "productId"))->toBe(None)
    })

    testSync("it carries the store identity and marks the type as its source", () => {
      let schema = S.schema(s =>
        {
          "imageUrl": s.matches(
            Reventless.StorageRef.forStore(~plugin="catalog", ~store="productImages"),
          ),
        }
      )->S.castToUnknown
      let json = SuryToJsonSchema.deriveObjectSchema(schema)
      let field = getPropertyOf(json, "imageUrl")
      expect(field->Option.flatMap(s => getProperty(s, "x-reventless-semantic-source")))->toEqual(
        Some(JSON.Encode.string("type")),
      )
      expect(field->Option.flatMap(s => getProperty(s, "x-reventless-semantic-target")))->toEqual(
        Some(
          JSON.Encode.object(
            Dict.fromArray([
              ("store", JSON.Encode.string("productImages")),
              ("plugin", JSON.Encode.string("catalog")),
            ]),
          ),
        ),
      )
    })

    testSync("the underlying string shape is unchanged", () => {
      // The marker refines an existing `string` field; nothing about what is
      // stored changes, which is why it can be retrofitted onto a live schema.
      let schema = S.schema(s =>
        {"imageUrl": s.matches(Reventless.StorageRef.forStore(~store="productImages"))}
      )->S.castToUnknown
      let json = SuryToJsonSchema.deriveObjectSchema(schema)
      expect(
        getPropertyOf(json, "imageUrl")->Option.flatMap(s => getProperty(s, "type")),
      )->toEqual(Some(JSON.Encode.string("string")))
    })

    // An optional field's marker sits inside the wrapper sury-ppx builds around
    // it, so this used to emit a plain nullable string: the field was a storage
    // ref in the source and an untyped string on the wire. The semantic now
    // survives, and it rides *beside* the nullable shape rather than replacing
    // it — a reader still learns the value may be absent.
    testSync("an optional storage-ref field keeps both its semantic and its nullability", () => {
      let schema = S.schema(s =>
        {"imageUrl": s.matches(S.option(Reventless.StorageRef.forStore(~store="productImages")))}
      )->S.castToUnknown
      let json = SuryToJsonSchema.deriveObjectSchema(schema)
      expect(semanticOf(json, "imageUrl"))->toEqual(Some(JSON.Encode.string("storageRef")))
      expect(
        getPropertyOf(json, "imageUrl")->Option.flatMap(s => getProperty(s, "oneOf"))->Option.isSome,
      )->toBe(true)
    })

    testSync("a type-carried semantic beats an annotation naming the same field", () => {
      let withSpec = (schema, spec) =>
        schema->S.Metadata.set(~id=Reventless.StateAnnotations.stateAnnotationsId, spec)
      let schema =
        S.schema(s =>
          {"imageUrl": s.matches(Reventless.StorageRef.forStore(~store="productImages"))}
        )
        ->S.castToUnknown
        ->withSpec({...emptySpec, semantic: [("imageUrl", "image")]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema)
      expect(semanticOf(json, "imageUrl"))->toEqual(Some(JSON.Encode.string("storageRef")))
    })
  })

  // The claim the branded scalars rest on: marking a field adds an annotation,
  // not a shape. A string stays a string and a number stays a number on the
  // wire, which is what makes them retrofittable onto a log that already has
  // events in it. One of each is enough — the emission path is the same for all
  // seven, and it is the *shape* half that is the load-bearing assertion here.
  describe("branded scalars keep their underlying shape:", () => {
    let fieldOf = (json, name) => getPropertyOf(json, name)
    let keyOf = (json, name, key) => fieldOf(json, name)->Option.flatMap(s => getProperty(s, key))

    let json = SuryToJsonSchema.deriveObjectSchema(
      S.schema(s =>
        {
          "contactEmail": s.matches(Reventless.Email.schema),
          "taxRate": s.matches(Reventless.Percent.schema),
        }
      )->S.castToUnknown,
    )

    testSync("a string scalar stays a string and carries its id", () =>
      expect((
        keyOf(json, "contactEmail", "type"),
        keyOf(json, "contactEmail", "x-reventless-semantic"),
      ))->toEqual((Some(JSON.Encode.string("string")), Some(JSON.Encode.string("email"))))
    )

    testSync("a numeric scalar stays a number and carries its id", () =>
      expect((
        keyOf(json, "taxRate", "type"),
        keyOf(json, "taxRate", "x-reventless-semantic"),
      ))->toEqual((Some(JSON.Encode.string("number")), Some(JSON.Encode.string("percent"))))
    )

    // The provenance half: a typed field outranks an annotated one, and this is
    // the key a consumer reads to tell them apart.
    testSync("both name the type as their source", () =>
      expect((
        keyOf(json, "contactEmail", "x-reventless-semantic-source"),
        keyOf(json, "taxRate", "x-reventless-semantic-source"),
      ))->toEqual((Some(JSON.Encode.string("type")), Some(JSON.Encode.string("type"))))
    )
  })

  // The other half of that claim, stated so it cannot be confused with it.
  // `Money` is the first semantic type that is *not* a brand: it turns a number
  // into an object, so the wire shape changes and stored events written against
  // the old field do not decode. The assertions below are the evidence for that
  // — a schema diff before and after a retype is exactly this, and it is what
  // says a deployment needs an upcaster before it can take the change.
  describe("Money changes the field's shape, and says so:", () => {
    let json = SuryToJsonSchema.deriveObjectSchema(
      S.schema(s =>
        {
          "price": s.matches(Reventless.Money.schema),
          "quantity": s.matches(S.float),
        }
      )->S.castToUnknown,
    )
    let keyOf = (name, key) => getPropertyOf(json, name)->Option.flatMap(s => getProperty(s, key))

    testSync("the field is an object, not a number", () =>
      expect(keyOf("price", "type"))->toEqual(Some(JSON.Encode.string("object")))
    )

    testSync("it carries the money id, sourced from the type", () =>
      expect((keyOf("price", "x-reventless-semantic"), keyOf("price", "x-reventless-semantic-source")))
      ->toEqual((Some(JSON.Encode.string("money")), Some(JSON.Encode.string("type"))))
    )

    // The control: an ordinary `float` price is what the field looked like
    // before, and it emits nothing at all. Without this the assertions above
    // would pass just as well against a schema that had always said `money`.
    testSync("a plain numeric field emits no semantic", () =>
      expect((keyOf("quantity", "type"), keyOf("quantity", "x-reventless-semantic")))->toEqual((
        Some(JSON.Encode.string("number")),
        None,
      ))
    )

    testSync("the amount and the currency both reach the wire", () => {
      let inner = getPropertyOf(json, "price")->Option.getOr(JSON.Encode.null)
      expect((
        getPropertyOf(inner, "amount")->Option.flatMap(s => getProperty(s, "type")),
        getPropertyOf(inner, "currency")->Option.flatMap(s => getProperty(s, "type")),
      ))->toEqual((Some(JSON.Encode.string("number")), Some(JSON.Encode.string("string"))))
    })

    // The closed currency arrives as an enum rather than a free string, which is
    // what lets a consumer build a currency picker instead of a text box — and
    // what makes `"eur"` unrepresentable on the wire as well as in the source.
    testSync("the currency is an enum of ISO codes", () => {
      let codes =
        getPropertyOf(json, "price")
        ->Option.getOr(JSON.Encode.null)
        ->getPropertyOf("currency")
        ->Option.flatMap(s => getProperty(s, "enum"))
        ->Option.flatMap(JSON.Decode.array)
        ->Option.getOr([])
        ->Array.filterMap(JSON.Decode.string)
      expect((
        codes->Array.length == Reventless.Currency.all->Array.length,
        codes->Array.includes("EUR"),
        codes->Array.includes("JPY"),
        codes->Array.includes("eur"),
      ))->toEqual((true, true, true, false))
    })
  })

  // The second composite, and the one whose emission the reader's shape rung
  // depends on. Like `Money` it turns the field into an object — same
  // shape-changed evidence, same upcaster warning for a collapse. Unlike it, the
  // two parts keep their own `dateTime` marker, so a walker that only understands
  // date-times still sees into the composite. That last property is asserted, not
  // described, because it is what lets the UI's primary rung key on the shape
  // before the `dateRange` marker reaches it in a release.
  describe("DateRange is an object whose parts stay date-times:", () => {
    let json = SuryToJsonSchema.deriveObjectSchema(
      S.schema(s =>
        {
          "deliveryWindow": s.matches(Reventless.DateRange.schema),
          "orderedAt": s.matches(Reventless.DateTime.string),
        }
      )->S.castToUnknown,
    )
    let keyOf = (name, key) => getPropertyOf(json, name)->Option.flatMap(s => getProperty(s, key))

    testSync("the field is an object, not a string", () =>
      expect(keyOf("deliveryWindow", "type"))->toEqual(Some(JSON.Encode.string("object")))
    )

    testSync("it carries the dateRange id, sourced from the type", () =>
      expect((
        keyOf("deliveryWindow", "x-reventless-semantic"),
        keyOf("deliveryWindow", "x-reventless-semantic-source"),
      ))->toEqual((Some(JSON.Encode.string("dateRange")), Some(JSON.Encode.string("type"))))
    )

    // The property that is not incidental: each part keeps its own date-time
    // marker under the composite. `dateTime` predates the generic marker and
    // surfaces as `format: "date-time"` (not `x-reventless-semantic`), so that is
    // what a walker reads to see the two instants without knowing about ranges.
    testSync("both instants keep their own date-time marker", () => {
      let inner = getPropertyOf(json, "deliveryWindow")->Option.getOr(JSON.Encode.null)
      expect((
        getPropertyOf(inner, "start")->Option.flatMap(s => getProperty(s, "format")),
        getPropertyOf(inner, "end")->Option.flatMap(s => getProperty(s, "format")),
      ))->toEqual((Some(JSON.Encode.string("date-time")), Some(JSON.Encode.string("date-time"))))
    })

    // The control, mirroring the `Money` block's plain-float case: a lone
    // date-time field stays a string and never becomes an object, so the
    // object-ness above is the composite's doing and not the walk's.
    testSync("a lone date-time field stays a string", () =>
      expect((keyOf("orderedAt", "type"), keyOf("orderedAt", "format")))->toEqual((
        Some(JSON.Encode.string("string")),
        Some(JSON.Encode.string("date-time")),
      ))
    )
  })
})
