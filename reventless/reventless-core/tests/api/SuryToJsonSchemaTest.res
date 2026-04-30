open Jest
open Expect

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
}

describe("SuryToJsonSchema:", () => {
  describe("deriveObjectSchema with no annotations:", () => {
    test("emits plain JSON Schema when no metadata is attached", () => {
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
  })

  describe("deriveObjectSchema with stateAnnotations metadata:", () => {
    let withSpec = (schema, spec) =>
      schema->S.Metadata.set(~id=Reventless.StateAnnotations.stateAnnotationsId, spec)

    test("emits x-reventless-id on field listed in ids", () => {
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

    test("emits x-reventless-compositeId on each compositeId field", () => {
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

    test("emits x-reventless-subId on field listed in subIds", () => {
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

    test("emits x-reventless-index as the index name when named", () => {
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

    test("emits x-reventless-index as true for unnamed @index", () => {
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

    test("does not emit x-reventless-* on unannotated fields", () => {
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

    test("emits x-reventless-hidden on field listed in hidden", () => {
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

    test("emits x-reventless-summary on field listed in summary", () => {
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

    test("emits x-reventless-drillTarget as the slice name", () => {
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

    test("emits x-reventless-drillTargetKey as the key path", () => {
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

    test("does not emit x-reventless-drillTargetKey when no key was supplied", () => {
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

    test("emits x-reventless-scan on field listed in scan", () => {
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

    test("emits x-reventless-scanSort on field listed in scanSort", () => {
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

    test("emits x-reventless-collapsed on field listed in collapsed", () => {
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

    test("properties keyset matches between deriveObjectSchema and S.toJSONSchema", () => {
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

    test("required array matches between deriveObjectSchema and S.toJSONSchema", () => {
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

    test("S.toJSONSchema does NOT emit x-reventless-* keys even when metadata is set", () => {
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
})
