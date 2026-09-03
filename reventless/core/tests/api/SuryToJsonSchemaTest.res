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
  lifecycle: None,
  groupBy: None,
  visibility: None,
  live: None,
  retired: None,
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

  describe("deriveObjectSchema with an owner field:", () => {
    let ownerOf = (json, name) =>
      getPropertyOf(json, name)->Option.flatMap(s => getProperty(s, "x-reventless-owner"))

    let json = SuryToJsonSchema.deriveObjectSchema(
      S.schema(s =>
        {
          "customerId": s.matches(Reventless.Owner.string),
          "note": s.matches(S.string),
        }
      )->S.castToUnknown,
    )

    testSync("the marked field carries x-reventless-owner", () =>
      expect(ownerOf(json, "customerId"))->toEqual(Some(JSON.Encode.bool(true)))
    )

    // The control: ownership is opt-in, and an unmarked string must stay one.
    // Without this, a bug that marked every field would still pass above.
    testSync("an unmarked string field carries nothing", () =>
      expect(ownerOf(json, "note"))->toBe(None)
    )

    testSync("the field is still a plain string on the wire", () =>
      expect(
        getPropertyOf(json, "customerId")->Option.flatMap(s => getProperty(s, "type")),
      )->toEqual(Some(JSON.Encode.string("string")))
    )

    // An optional field keeps its marker inside the union wrapper. A reader that
    // only inspects the outer schema answers "not the owner" here — which for a
    // predicate that scopes reads means an unscoped view, silently. This is the
    // case `Owner.isFieldOwner` exists for.
    testSync("an optional owner field is still recognised", () => {
      let optJson = SuryToJsonSchema.deriveObjectSchema(
        S.schema(s =>
          {
            "customerId": s.matches(S.option(Reventless.Owner.string)),
          }
        )->S.castToUnknown,
      )
      expect(ownerOf(optJson, "customerId"))->toEqual(Some(JSON.Encode.bool(true)))
    })
  })

  describe("deriveObjectSchema with a sensitive field:", () => {
    let sensitiveOf = (json, name) =>
      getPropertyOf(json, name)->Option.flatMap(s => getProperty(s, "x-reventless-sensitive"))
    let ownerOf = (json, name) =>
      getPropertyOf(json, name)->Option.flatMap(s => getProperty(s, "x-reventless-owner"))

    let json = SuryToJsonSchema.deriveObjectSchema(
      S.schema(s =>
        {
          "resetToken": s.matches(Reventless.Sensitive.string),
          "note": s.matches(S.string),
          "contact": s.matches(Reventless.Email.schema),
        }
      )->S.castToUnknown,
    )

    testSync("the marked field carries x-reventless-sensitive", () =>
      expect(sensitiveOf(json, "resetToken"))->toEqual(Some(JSON.Encode.bool(true)))
    )

    // The control. Absent means "not stated", and a reader that misses the
    // marker renders the value — so a bug that marked everything would look like
    // caution while a bug that marked nothing leaks. Both need catching, and
    // only this assertion catches the first.
    testSync("an unmarked string field carries nothing", () =>
      expect(sensitiveOf(json, "note"))->toBe(None)
    )

    // A contact detail is sensitive whether or not anybody wrote it down: the
    // whole meaning of the semantic is "how to reach a particular person".
    testSync("an email field is sensitive with no annotation", () =>
      expect(sensitiveOf(json, "contact"))->toEqual(Some(JSON.Encode.bool(true)))
    )

    testSync("the field is still a plain string on the wire", () =>
      expect(
        getPropertyOf(json, "resetToken")->Option.flatMap(s => getProperty(s, "type")),
      )->toEqual(Some(JSON.Encode.string("string")))
    )

    // Same trap as the owner case, and worse in consequence: a reader that only
    // inspects the outer schema answers "not sensitive" for an optional field,
    // and the value goes into a message.
    testSync("an optional sensitive field is still recognised", () => {
      let optJson = SuryToJsonSchema.deriveObjectSchema(
        S.schema(s =>
          {
            "resetToken": s.matches(S.option(Reventless.Sensitive.string)),
          }
        )->S.castToUnknown,
      )
      expect(sensitiveOf(optJson, "resetToken"))->toEqual(Some(JSON.Encode.bool(true)))
    })

    // The composition rule. `mark` wraps rather than replaces, so a field that
    // is both an owner and sensitive keeps both — a marker that silently
    // replaced the other would unscope a view or unmask a value.
    testSync("sensitivity composes with ownership on one field", () => {
      let bothJson = SuryToJsonSchema.deriveObjectSchema(
        S.schema(s =>
          {
            "customerId": s.matches(Reventless.Sensitive.mark(Reventless.Owner.string)),
          }
        )->S.castToUnknown,
      )
      expect((sensitiveOf(bothJson, "customerId"), ownerOf(bothJson, "customerId")))->toEqual((
        Some(JSON.Encode.bool(true)),
        Some(JSON.Encode.bool(true)),
      ))
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

    // `@internal` drops the property rather than marking it. A marker is the
    // right answer for a field that is on the surface and merely unwanted — that
    // is `@hidden`, above. This one is not on the surface at all, so an entry
    // here would describe a field the SDL does not declare, which is the
    // mismatch that makes a generated list query name fields the server rejects.
    testSync("drops a field listed in internal rather than annotating it", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "eventCollector": s.matches(S.string),
        }
      )->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, internal: ["eventCollector"]})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      expect((
        getPropertyOf(json, "eventCollector")->Option.isNone,
        getPropertyOf(json, "id")->Option.isSome,
      ))->toEqual((true, true))
    })

    // A dropped property must not be left behind in `required`, or a consumer
    // building a form from the schema asks for a field it was never given.
    testSync("keeps a dropped field out of required", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "eventCollector": s.matches(S.string),
        }
      )->S.castToUnknown
      let json =
        schema
        ->withSpec({...emptySpec, internal: ["eventCollector"]})
        ->SuryToJsonSchema.deriveObjectSchema
      expect(
        json
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("required"))
        ->Option.flatMap(JSON.Decode.array)
        ->Option.getOr([])
        ->Array.filterMap(JSON.Decode.string),
      )->toEqual(["id"])
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

    testSync("emits x-reventless-retired {label,showWhenFalse} on the retired field", () => {
      let schema = S.schema(s =>
        {
          "id": s.matches(S.string),
          "archived": s.matches(S.bool),
        }
      )->S.castToUnknown
      let schema' =
        schema->withSpec({
          ...emptySpec,
          retired: Some({field: "archived", label: "Archived", showWhenFalse: true, values: None, namedWhenRetired: false}),
        })
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let retiredObj =
        getPropertyOf(json, "archived")->Option.flatMap(s => getProperty(s, "x-reventless-retired"))
      expect((
        retiredObj->Option.flatMap(r => getProperty(r, "label"))->Option.flatMap(JSON.Decode.string),
        retiredObj
        ->Option.flatMap(r => getProperty(r, "showWhenFalse"))
        ->Option.flatMap(JSON.Decode.bool),
        // Only the named field carries it.
        getPropertyOf(json, "id")->Option.flatMap(s => getProperty(s, "x-reventless-retired")),
      ))->toEqual((Some("Archived"), Some(true), None))
    })

    // The state form. `values` is what tells a consumer which of the two forms a
    // view declared, so it travels on the same key and only when present.
    let stateFormJson = (~values: array<string>) => {
      let schema = S.schema(s =>
        {
          "customerId": s.matches(S.string),
          "accountStatus": s.matches(S.union([S.literal("Active"), S.literal("Deactivated")])),
        }
      )->S.castToUnknown
      schema
      ->withSpec({
        ...emptySpec,
        lifecycle: Some("accountStatus"),
        retired: Some({
          field: "accountStatus",
          label: "",
          showWhenFalse: false,
          values: Some(values),
          namedWhenRetired: false,
        }),
      })
      ->SuryToJsonSchema.deriveObjectSchema
    }

    let retiredOn = (json, field) =>
      getPropertyOf(json, field)->Option.flatMap(s => getProperty(s, "x-reventless-retired"))

    let stringsAt = (retiredObj, key) =>
      retiredObj
      ->Option.flatMap(r => getProperty(r, key))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.map(a => a->Array.filterMap(JSON.Decode.string))

    testSync("carries one retirement state as a one-element set", () => {
      expect(
        stateFormJson(~values=["Deactivated"])->retiredOn("accountStatus")->stringsAt("values"),
      )->toEqual(Some(["Deactivated"]))
    })

    testSync("carries every retirement state a lifecycle declares", () => {
      expect(
        stateFormJson(~values=["Archived", "Discontinued"])
        ->retiredOn("accountStatus")
        ->stringsAt("values"),
      )->toEqual(Some(["Archived", "Discontinued"]))
    })

    // The transitional key, for one release. A consumer pinned before the set
    // degrades to nothing at all rather than to a missing badge — and enforcement
    // never depended on it, so the whole of the lag is cosmetic either way.
    testSync("emits the singular value beside a one-element set", () => {
      expect(
        stateFormJson(~values=["Deactivated"])
        ->retiredOn("accountStatus")
        ->Option.flatMap(r => getProperty(r, "value"))
        ->Option.flatMap(JSON.Decode.string),
      )->toEqual(Some("Deactivated"))
    })

    // There is no singular reading of two states, so the shim simply stops. A
    // consumer that understands only `value` sees no retirement rather than one
    // of the two picked arbitrarily.
    testSync("omits the singular value for a set of two", () => {
      expect(
        stateFormJson(~values=["Archived", "Discontinued"])
        ->retiredOn("accountStatus")
        ->Option.flatMap(r => getProperty(r, "value")),
      )->toEqual(None)
    })

    // Absent rather than null: a consumer reads the key's absence as "the boolean
    // form", the same way it reads an absent label as "derive one from the name".
    testSync("omits both value and values entirely on the boolean form", () => {
      let schema = S.schema(s => {"archived": s.matches(S.bool)})->S.castToUnknown
      let schema' =
        schema->withSpec({
          ...emptySpec,
          retired: Some({field: "archived", label: "", showWhenFalse: false, values: None, namedWhenRetired: false}),
        })
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let retiredObj = json->retiredOn("archived")
      expect((
        retiredObj->Option.flatMap(r => getProperty(r, "value")),
        retiredObj->Option.flatMap(r => getProperty(r, "values")),
      ))->toEqual((None, None))
    })

    // The opt-in that lets a reference name a withheld row. Travels only when
    // true, on the omit-the-default rule the keys around it follow: false is what
    // every record said before it existed, and writing it would put a key on
    // every retirement to report that nothing changed.
    testSync("carries namedWhenRetired only when the record opted in", () => {
      let build = (~named: bool) => {
        let schema = S.schema(s => {"archived": s.matches(S.bool)})->S.castToUnknown
        schema
        ->withSpec({
          ...emptySpec,
          retired: Some({
            field: "archived",
            label: "",
            showWhenFalse: false,
            values: None,
            namedWhenRetired: named,
          }),
        })
        ->SuryToJsonSchema.deriveObjectSchema
        ->retiredOn("archived")
        ->Option.flatMap(r => getProperty(r, "namedWhenRetired"))
        ->Option.flatMap(JSON.Decode.bool)
      }
      expect((build(~named=true), build(~named=false)))->toEqual((Some(true), None))
    })

    testSync("omits the retired label when empty but always states showWhenFalse", () => {
      let schema = S.schema(s => {"deactivated": s.matches(S.bool)})->S.castToUnknown
      let schema' =
        schema->withSpec({
          ...emptySpec,
          retired: Some({field: "deactivated", label: "", showWhenFalse: false, values: None, namedWhenRetired: false}),
        })
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      let retiredObj =
        getPropertyOf(json, "deactivated")->Option.flatMap(s =>
          getProperty(s, "x-reventless-retired")
        )
      expect((
        retiredObj->Option.flatMap(r => getProperty(r, "label")),
        retiredObj
        ->Option.flatMap(r => getProperty(r, "showWhenFalse"))
        ->Option.flatMap(JSON.Decode.bool),
      ))->toEqual((None, Some(false)))
    })

    testSync("emits nothing for a schema with no retired annotation", () => {
      let schema = S.schema(s => {"archived": s.matches(S.bool)})->S.castToUnknown
      let json = SuryToJsonSchema.deriveObjectSchema(schema->withSpec(emptySpec))
      expect(
        getPropertyOf(json, "archived")->Option.flatMap(s => getProperty(s, "x-reventless-retired")),
      )->toBe(None)
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

    testSync("emits x-reventless-live at top level when live is declared", () => {
      let schema = S.schema(s => {"id": s.matches(S.string)})->S.castToUnknown
      let offJson = SuryToJsonSchema.deriveObjectSchema(
        schema->withSpec({...emptySpec, live: Some(false)}),
      )
      let onJson = SuryToJsonSchema.deriveObjectSchema(
        schema->withSpec({...emptySpec, live: Some(true)}),
      )
      expect((
        getProperty(offJson, "x-reventless-live")->Option.flatMap(JSON.Decode.bool),
        getProperty(onJson, "x-reventless-live")->Option.flatMap(JSON.Decode.bool),
      ))->toEqual((Some(false), Some(true)))
    })

    testSync("omits x-reventless-live when live is None (no annotation)", () => {
      let schema = S.schema(s => {"id": s.matches(S.string)})->S.castToUnknown
      let schema' = schema->withSpec({...emptySpec, live: None})
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      expect(getProperty(json, "x-reventless-live"))->toBe(None)
    })

    testSync("emits x-reventless-live and x-reventless-visibility together", () => {
      let schema = S.schema(s => {"id": s.matches(S.string)})->S.castToUnknown
      let schema' = schema->withSpec({
        ...emptySpec,
        visibility: Some("Internal"),
        live: Some(false),
      })
      let json = SuryToJsonSchema.deriveObjectSchema(schema')
      expect((
        getProperty(json, "x-reventless-visibility")->Option.flatMap(JSON.Decode.string),
        getProperty(json, "x-reventless-live")->Option.flatMap(JSON.Decode.bool),
      ))->toEqual((Some("Internal"), Some(false)))
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

  // A selection, not an input. The whole point of the id is that it travels the
  // same channel as a store declaration and says something a store declaration
  // cannot: the candidates are on the row, so nothing is provisioned for it.
  describe("a member-reference field:", () => {
    let targetOf = (json, name) =>
      getPropertyOf(json, name)->Option.flatMap(s =>
        getProperty(s, "x-reventless-semantic-target")
      )

    testSync("carries the collection, the view holding it, and what a member is", () => {
      let json = SuryToJsonSchema.deriveObjectSchema(
        S.schema(s =>
          {
            "productImage": s.matches(
              Reventless.MemberRef.of_(
                ~view="Products",
                ~content=Reventless.Semantic.Id.imageRef,
                ~field="productImages",
              ),
            ),
          }
        )->S.castToUnknown,
      )
      expect(
        getPropertyOf(json, "productImage")->Option.flatMap(s =>
          getProperty(s, "x-reventless-semantic")
        ),
      )->toEqual(Some(JSON.Encode.string("memberRef")))
      expect(targetOf(json, "productImage"))->toEqual(
        Some(
          JSON.Encode.object(
            Dict.fromArray([
              ("field", JSON.Encode.string("productImages")),
              ("view", JSON.Encode.string("Products")),
              ("content", JSON.Encode.string("imageRef")),
            ]),
          ),
        ),
      )
    })

    // The second position: a declaration on a view's own state, where the
    // collection is on the same record and naming a view would invite the reader
    // to think another one could be meant.
    testSync("omits the view where the collection is on this very record", () =>
      expect(
        targetOf(
          SuryToJsonSchema.deriveObjectSchema(
            S.schema(s =>
              {"productImage": s.matches(Reventless.MemberRef.of_(~field="productImages"))}
            )->S.castToUnknown,
          ),
          "productImage",
        ),
      )->toEqual(
        Some(JSON.Encode.object(Dict.fromArray([("field", JSON.Encode.string("productImages"))]))),
      )
    )

    // The assertion the whole design rests on, and the one a reader will want to
    // see rather than infer: a `memberRef` field declares NO store, so the
    // provisioning walk passes it by and no upload endpoint is bound. This is
    // exactly what `imageRef` gets today, reached through a different payload.
    testSync("declares no store, so nothing is provisioned for it", () =>
      expect(
        Reventless.StorageRef.getFieldStore(
          Reventless.MemberRef.of_(~view="Products", ~field="productImages"),
        ),
      )->toBe(None)
    )

    testSync("stays a plain string on the wire", () =>
      expect(
        getPropertyOf(
          SuryToJsonSchema.deriveObjectSchema(
            S.schema(s =>
              {"productImage": s.matches(Reventless.MemberRef.of_(~field="productImages"))}
            )->S.castToUnknown,
          ),
          "productImage",
        )->Option.flatMap(s => getProperty(s, "type")),
      )->toEqual(Some(JSON.Encode.string("string")))
    )
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

  // The third composite. Its emission matters more than the other two's, because
  // the reader has been resolving this shape from a *heuristic* since before the
  // marker existed: an object with numeric `lat`/`lng` sub-properties already
  // resolves to the geo-point semantic by shape. So the assertions below are what
  // separate a declaration from a lucky guess — the marker and its `type` source.
  describe("GeoPoint is an object carrying the geoPoint marker:", () => {
    let json = SuryToJsonSchema.deriveObjectSchema(
      S.schema(s =>
        {
          "location": s.matches(Reventless.GeoPoint.schema),
          "lat": s.matches(S.float),
        }
      )->S.castToUnknown,
    )
    let keyOf = (name, key) => getPropertyOf(json, name)->Option.flatMap(s => getProperty(s, key))

    testSync("the field is an object, not a pair of numbers", () =>
      expect(keyOf("location", "type"))->toEqual(Some(JSON.Encode.string("object")))
    )

    testSync("it carries the geoPoint id, sourced from the type", () =>
      expect((
        keyOf("location", "x-reventless-semantic"),
        keyOf("location", "x-reventless-semantic-source"),
      ))->toEqual((Some(JSON.Encode.string("geoPoint")), Some(JSON.Encode.string("type"))))
    )

    // The control, and the whole reason the composite exists: a bare `lat` float
    // is exactly what the flattened pair looked like, and it emits nothing at
    // all. Everything a map knew about it, it inferred from the name.
    testSync("a bare lat float emits no semantic", () =>
      expect((keyOf("lat", "type"), keyOf("lat", "x-reventless-semantic")))->toEqual((
        Some(JSON.Encode.string("number")),
        None,
      ))
    )

    testSync("both coordinates reach the wire as numbers", () => {
      let inner = getPropertyOf(json, "location")->Option.getOr(JSON.Encode.null)
      expect((
        getPropertyOf(inner, "lat")->Option.flatMap(s => getProperty(s, "type")),
        getPropertyOf(inner, "lng")->Option.flatMap(s => getProperty(s, "type")),
      ))->toEqual((Some(JSON.Encode.string("number")), Some(JSON.Encode.string("number"))))
    })
  })

  // A nested record's own optional field. `optional` is computed for the schema
  // handed to `deriveObjectSchema` and not threaded into `ObjectRef`, so a field
  // one level in has only its nullable wrapper to say it may be absent — and the
  // wrapper is exactly what a reader looking at `required` never sees.
  describe("an optional field inside a nested record:", () => {
    let inner = S.schema(s =>
      {
        "street": s.matches(S.string),
        "unit": s.matches(S.option(S.string)),
      }
    )
    let json = SuryToJsonSchema.deriveObjectSchema(
      S.schema(s =>
        {
          "id": s.matches(S.string),
          "address": s.matches(inner),
        }
      )->S.castToUnknown,
    )
    let nestedRequired =
      getPropertyOf(json, "address")
      ->Option.flatMap(a => getProperty(a, "required"))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filterMap(JSON.Decode.string)

    testSync("is not listed as required", () =>
      expect(nestedRequired->Array.includes("unit"))->toBe(false)
    )

    testSync("while its non-optional sibling still is", () =>
      expect(nestedRequired->Array.includes("street"))->toBe(true)
    )
  })

})
