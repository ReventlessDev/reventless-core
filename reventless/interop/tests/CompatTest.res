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

// A9: SemVer parsing + protocol compatibility. Regression coverage for the
// prerelease bug — every `-alpha` version parsed as None and was reported
// incompatible — and the new malformed-vs-incompatible distinction.
let host = (~cmd, ~evt): ExtensionPointProtocol.schemaVersions => {
  commandVersion: cmd,
  eventVersion: evt,
}
let ep = "Catalog.Products"
let check = (~hostCmd, ~hostEvt, ~extCmd, ~extEvt) =>
  Compat.validateProtocol(
    ~host=host(~cmd=hostCmd, ~evt=hostEvt),
    ~extensionPointName=ep,
    ~commandVersion=extCmd,
    ~eventVersion=extEvt,
  )

describe("Compat.validateProtocol", () => {
  testSync("exact match is compatible", () => {
    expect(check(~hostCmd="1.2.3", ~hostEvt="1.2.3", ~extCmd="1.2.3", ~extEvt="1.2.3"))->toEqual([])
  })

  testSync("host minor ahead is compatible", () => {
    expect(check(~hostCmd="1.3.0", ~hostEvt="1.3.0", ~extCmd="1.2.9", ~extEvt="1.2.9"))->toEqual([])
  })

  testSync("host minor behind is incompatible (command only, event matches)", () => {
    let errs = check(~hostCmd="1.1.0", ~hostEvt="1.2.0", ~extCmd="1.2.0", ~extEvt="1.2.0")
    expect(errs->Array.length)->toBe(1)
    switch errs->Array.get(0) {
    | Some(Compat.IncompatibleCommandSchema(_)) => expect(true)->toBe(true)
    | _ => expect(true)->toBe(false)
    }
  })

  testSync("major mismatch is incompatible", () => {
    let errs = check(~hostCmd="2.0.0", ~hostEvt="1.0.0", ~extCmd="1.0.0", ~extEvt="1.0.0")
    expect(errs->Array.length)->toBe(1)
  })

  testSync("host patch behind at equal minor is incompatible", () => {
    let errs = check(~hostCmd="1.2.3", ~hostEvt="1.2.5", ~extCmd="1.2.5", ~extEvt="1.2.5")
    expect(errs->Array.length)->toBe(1)
  })

  testSync("prerelease versions are compatible — the -alpha suffix is ignored", () => {
    // The headline fix: without prerelease stripping these parsed as None and
    // were falsely reported incompatible.
    expect(
      check(
        ~hostCmd="1.0.0-alpha.62",
        ~hostEvt="1.0.0-alpha.62",
        ~extCmd="1.0.0-alpha.5",
        ~extEvt="1.0.0-alpha.5",
      ),
    )->toEqual([])
  })

  testSync("build metadata is ignored", () => {
    expect(
      check(~hostCmd="1.2.3+abc", ~hostEvt="1.2.3", ~extCmd="1.2.3", ~extEvt="1.2.3"),
    )->toEqual([])
  })

  testSync("a malformed version yields MalformedVersion, not a bogus incompatibility", () => {
    let errs = check(~hostCmd="not-a-version", ~hostEvt="1.0.0", ~extCmd="1.0.0", ~extEvt="1.0.0")
    switch errs->Array.get(0) {
    | Some(Compat.MalformedVersion({version})) => expect(version)->toBe("not-a-version")
    | _ => expect(true)->toBe(false)
    }
  })
})

describe("Compat.parseSemVer", () => {
  testSync("parses a plain version", () => {
    expect(Compat.parseSemVer("1.2.3"))->toEqual(Some((1, 2, 3)))
  })
  testSync("strips a prerelease suffix", () => {
    expect(Compat.parseSemVer("1.0.0-alpha.62"))->toEqual(Some((1, 0, 0)))
  })
  testSync("strips build metadata", () => {
    expect(Compat.parseSemVer("2.5.1+build.9"))->toEqual(Some((2, 5, 1)))
  })
  testSync("returns None for a non-version string", () => {
    expect(Compat.parseSemVer("nope"))->toEqual(None)
  })
  testSync("returns None for a too-short core", () => {
    expect(Compat.parseSemVer("1.2"))->toEqual(None)
  })
})
