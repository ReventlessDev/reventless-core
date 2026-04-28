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
      let schema' = schema->withSpec({
        ids: ["entityId"],
        compositeIds: [],
        subIds: [],
        compositeSubIds: [],
        indexes: [],
        hidden: [],
        summary: [],
      })
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
        ids: [],
        compositeIds: ["environment", "platformName"],
        subIds: [],
        compositeSubIds: [],
        indexes: [],
        hidden: [],
        summary: [],
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
      let schema' = schema->withSpec({
        ids: [],
        compositeIds: [],
        subIds: ["version"],
        compositeSubIds: [],
        indexes: [],
        hidden: [],
        summary: [],
      })
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
        ids: [],
        compositeIds: [],
        subIds: [],
        compositeSubIds: [],
        indexes: [("ownerId", "byOwner")],
        hidden: [],
        summary: [],
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
        ids: [],
        compositeIds: [],
        subIds: [],
        compositeSubIds: [],
        indexes: [("category", "")],
        hidden: [],
        summary: [],
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
      let schema' = schema->withSpec({
        ids: ["entityId"],
        compositeIds: [],
        subIds: [],
        compositeSubIds: [],
        indexes: [],
        hidden: [],
        summary: [],
      })
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
      let schema' = schema->withSpec({
        ids: [],
        compositeIds: [],
        subIds: [],
        compositeSubIds: [],
        indexes: [],
        hidden: ["deploymentId"],
        summary: [],
      })
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
      let schema' = schema->withSpec({
        ids: [],
        compositeIds: [],
        subIds: [],
        compositeSubIds: [],
        indexes: [],
        hidden: [],
        summary: ["pluginName"],
      })
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
  })
})
