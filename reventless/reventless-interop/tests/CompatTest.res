open JestGlobals

// Helpers

// Minimal ExportMeta.t with the given field manifest
let makeMeta = (fields: array<(string, array<string>)>): ExportMeta.t => {
  version: "0.1.0",
  fields: Dict.fromArray(fields),
}

// A fromJson that always succeeds, returning a fixed string
let alwaysOkFromJson = (_json: JSON.t) => Ok("ok")

// A fromJson that always fails
let alwaysErrorFromJson = (_json: JSON.t) => Error("decode failed")

// Minimal valid JSON object value
let emptyJsonObject: JSON.t = %raw(`{}`)

describe("Compat.validateAndProject", () => {
  describe("required field validation", () => {
    testSync("succeeds when all required fields are in the manifest", () => {
      let meta = makeMeta([("tasks", ["name", "bucketNames"])])
      let result = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name", "bucketNames"],
        ~fromJson=alwaysOkFromJson,
      )
      expect(result)->toEqual(Ok("ok"))
    })

    testSync("succeeds when requiredFields is empty", () => {
      let meta = makeMeta([("tasks", [])])
      let result = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=[],
        ~fromJson=alwaysOkFromJson,
      )
      expect(result)->toEqual(Ok("ok"))
    })

    testSync("fails with MissingRequiredField when a required field is absent", () => {
      let meta = makeMeta([("tasks", ["name"])])
      let result = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name", "bucketNames"],
        ~fromJson=alwaysOkFromJson,
      )
      expect(result)->toEqual(
        Error(
          Compat.MissingRequiredField({
            stackName: "org/plugin/prod",
            outputName: "tasks",
            field: "bucketNames",
          }),
        ),
      )
    })

    testSync("fails when manifest for outputName is absent entirely", () => {
      // meta has no entry for "tasks" — treated as empty field list
      let meta = makeMeta([("plugin", ["id", "version"])])
      let result = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name"],
        ~fromJson=alwaysOkFromJson,
      )
      expect(result)->toEqual(
        Error(
          Compat.MissingRequiredField({
            stackName: "org/plugin/prod",
            outputName: "tasks",
            field: "name",
          }),
        ),
      )
    })

    testSync("includes the first missing field in the error (not all missing fields)", () => {
      // Only the first missing field is reported — consumers fix one at a time
      let meta = makeMeta([("tasks", [])])
      let result = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name", "bucketNames"],
        ~fromJson=alwaysOkFromJson,
      )
      switch result {
      | Error(Compat.MissingRequiredField({field})) => expect(field)->toBe("name")
      | _ => expect(true)->toBe(false)
      }
    })
  })

  describe("fromJson decoding", () => {
    testSync("calls fromJson when all required fields are present", () => {
      let meta = makeMeta([("tasks", ["name"])])
      let called = ref(false)
      let trackingFromJson = (json: JSON.t) => {
        called := true
        alwaysOkFromJson(json)
      }
      let _ = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name"],
        ~fromJson=trackingFromJson,
      )
      expect(called.contents)->toBe(true)
    })

    testSync("does not call fromJson when a required field is missing", () => {
      let meta = makeMeta([("tasks", [])])
      let called = ref(false)
      let trackingFromJson = (json: JSON.t) => {
        called := true
        alwaysOkFromJson(json)
      }
      let _ = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name"],
        ~fromJson=trackingFromJson,
      )
      expect(called.contents)->toBe(false)
    })

    testSync("wraps fromJson error in DecodeFailed", () => {
      let meta = makeMeta([("tasks", ["name"])])
      let result = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name"],
        ~fromJson=alwaysErrorFromJson,
      )
      expect(result)->toEqual(
        Error(
          Compat.DecodeFailed({stackName: "org/plugin/prod", reason: "decode failed"}),
        ),
      )
    })

    testSync("passes the raw JSON value to fromJson unchanged", () => {
      let meta = makeMeta([("plugin", ["id"])])
      let jsonInput: JSON.t = %raw(`{"id": "test-plugin", "version": "1.0.0"}`)
      let capturedJson = ref(None)
      let capturingFromJson = (json: JSON.t) => {
        capturedJson := Some(json)
        Ok("captured")
      }
      let _ = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="plugin",
        ~rawJson=jsonInput,
        ~requiredFields=["id"],
        ~fromJson=capturingFromJson,
      )
      expect(capturedJson.contents->Option.isSome)->toBe(true)
    })
  })

  describe("optional fields", () => {
    testSync("does not require optional fields to be in the manifest", () => {
      // Projection has optional fields; they are not validated against the manifest
      let meta = makeMeta([("tasks", ["name"])])
      let result = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name"],
        ~fromJson=alwaysOkFromJson,
      )
      // optionalFields is not a parameter of validateAndProject — it's used by
      // consumers to document intent; validation only checks requiredFields
      expect(result)->toEqual(Ok("ok"))
    })
  })

  describe("stackName in errors", () => {
    testSync("uses the provided stackName in MissingRequiredField error", () => {
      let meta = makeMeta([("tasks", [])])
      let result = Compat.validateAndProject(
        ~stackName="myorg/my-plugin/staging",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name"],
        ~fromJson=alwaysOkFromJson,
      )
      switch result {
      | Error(Compat.MissingRequiredField({stackName})) =>
        expect(stackName)->toBe("myorg/my-plugin/staging")
      | _ => expect(true)->toBe(false)
      }
    })

    testSync("uses the provided stackName in DecodeFailed error", () => {
      let meta = makeMeta([("tasks", ["name"])])
      let result = Compat.validateAndProject(
        ~stackName="myorg/my-plugin/staging",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name"],
        ~fromJson=alwaysErrorFromJson,
      )
      switch result {
      | Error(Compat.DecodeFailed({stackName})) =>
        expect(stackName)->toBe("myorg/my-plugin/staging")
      | _ => expect(true)->toBe(false)
      }
    })
  })

  describe("field manifest boundary cases", () => {
    testSync("succeeds when manifest has more fields than required", () => {
      // Publisher exports extra fields — consumer only requires a subset
      let meta = makeMeta([("tasks", ["name", "bucketNames", "sideEffectSources"])])
      let result = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=["name"],
        ~fromJson=alwaysOkFromJson,
      )
      expect(result)->toEqual(Ok("ok"))
    })

    testSync("succeeds with empty required fields even when manifest is empty", () => {
      let meta = makeMeta([("tasks", [])])
      let result = Compat.validateAndProject(
        ~stackName="org/plugin/prod",
        ~meta,
        ~outputName="tasks",
        ~rawJson=emptyJsonObject,
        ~requiredFields=[],
        ~fromJson=alwaysOkFromJson,
      )
      expect(result)->toEqual(Ok("ok"))
    })
  })
})
