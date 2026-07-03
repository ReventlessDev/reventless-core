// Structured JSON formatter — the AI loop's primary input and the substrate
// for any programmatic consumer. Ships both a single-envelope mode and an
// NDJSON streaming mode (`--stream`). Shape matches §3.3 of
// `docs/analysis/given-when-then-specifications.md`.

// 1.1.0 — additive: `PublishedActionsMismatch` mismatch kind for the
// Delegate_GWT / cross-plugin Flow_GWT boundary steps.
// The default the emitted envelope carries; the `--schema-version` CLI flag
// overrides it (threaded through `emit` / `streamRunStart`) so a consumer can
// pin the schema version its AI prompt was built against.
let defaultSchemaVersion = "1.1.0"

@val external processStdout: {"write": string => unit} = "process.stdout"
let write = (s: string) => processStdout["write"](s)
let writeLine = (s: string) => write(s ++ "\n")

// Re-render a JSON value as a dual-rendered `{type, payload, rendered}` entry.
let renderValue = (j: JSON.t): JSON.t => {
  let obj = Dict.make()
  switch j {
  | Object(dict) =>
    switch dict->Dict.get("TAG") {
    | Some(String(tag)) => {
        obj->Dict.set("type", JSON.Encode.string(tag))
        let payloadKeys =
          dict
          ->Dict.keysToArray
          ->Array.filter(k => k != "TAG" && String.startsWith(k, "_"))
        let payload = switch payloadKeys {
        | [] => JSON.Encode.null
        | ["_0"] =>
          dict->Dict.get("_0")->Option.getOr(JSON.Encode.null)
        | _ => {
            let payloadDict = Dict.make()
            payloadKeys->Array.forEach(k =>
              payloadDict->Dict.set(
                k,
                dict->Dict.get(k)->Option.getOr(JSON.Encode.null),
              )
            )
            JSON.Encode.object(payloadDict)
          }
        }
        obj->Dict.set("payload", payload)
      }
    | _ => {
        obj->Dict.set("type", JSON.Encode.null)
        obj->Dict.set("payload", j)
      }
    }
  | String(s) => {
      obj->Dict.set("type", JSON.Encode.string(s))
      obj->Dict.set("payload", JSON.Encode.null)
    }
  | _ => {
      obj->Dict.set("type", JSON.Encode.null)
      obj->Dict.set("payload", j)
    }
  }
  obj->Dict.set("rendered", JSON.Encode.string(RenderRescript.render(j)))
  JSON.Encode.object(obj)
}

let renderValues = (arr: array<JSON.t>): JSON.t =>
  arr->Array.map(renderValue)->JSON.Encode.array

let mismatchJson = (m: Outcome.mismatch, slice: option<string>): JSON.t => {
  let obj = Dict.make()
  obj->Dict.set("kind", JSON.Encode.string(Outcome.kindName(m)))
  let optVal = o =>
    switch o {
    | Some(v) => renderValue(v)
    | None => JSON.Encode.null
    }
  switch m {
  | EventsMismatch({expected, actual}) => {
      obj->Dict.set("expected", renderValues(expected))
      obj->Dict.set("actual", renderValues(actual))
      obj->Dict.set("fieldDiff", Diff.toJsonArray(Diff.diffArrays(expected, actual)))
    }
  | ErrorMismatch({expected, actual, actualEvents}) => {
      obj->Dict.set("expected", renderValue(expected))
      obj->Dict.set("actual", optVal(actual))
      obj->Dict.set("actualEvents", renderValues(actualEvents))
    }
  | StateMismatch({key, expected, actual}) => {
      obj->Dict.set("key", JSON.Encode.string(key))
      obj->Dict.set("expected", optVal(expected))
      obj->Dict.set("actual", optVal(actual))
      let eJson = expected->Option.getOr(JSON.Encode.null)
      let aJson = actual->Option.getOr(JSON.Encode.null)
      obj->Dict.set("fieldDiff", Diff.toJsonArray(Diff.diff(eJson, aJson)))
    }
  | NoEventExpected({actual}) => obj->Dict.set("actual", renderValues(actual))
  | TodoMismatch({expected, actual}) => {
      let pairArr = pairs =>
        pairs
        ->Array.map(((id, v)) => {
          let d = Dict.make()
          d->Dict.set("id", JSON.Encode.string(id))
          d->Dict.set("value", renderValue(v))
          JSON.Encode.object(d)
        })
        ->JSON.Encode.array
      obj->Dict.set("expected", pairArr(expected))
      obj->Dict.set("actual", pairArr(actual))
    }
  | AppendConditionMismatch({expected, actual}) => {
      obj->Dict.set("expected", expected)
      obj->Dict.set("actual", actual)
    }
  | TranslateError({expected, actual}) => {
      obj->Dict.set("expected", JSON.Encode.string(expected))
      obj->Dict.set(
        "actual",
        actual->Option.mapOr(JSON.Encode.null, JSON.Encode.string),
      )
    }
  | QueryRowsMismatch({expected, actual}) => {
      obj->Dict.set("expected", renderValues(expected))
      obj->Dict.set("actual", renderValues(actual))
      obj->Dict.set("fieldDiff", Diff.toJsonArray(Diff.diffArrays(expected, actual)))
    }
  | PublishedActionsMismatch({expected, actual}) => {
      obj->Dict.set("expected", renderValues(expected))
      obj->Dict.set("actual", renderValues(actual))
      obj->Dict.set("fieldDiff", Diff.toJsonArray(Diff.diffArrays(expected, actual)))
    }
  | Throw({error, stack}) => {
      obj->Dict.set("error", JSON.Encode.string(error))
      obj->Dict.set("stack", JSON.Encode.string(stack))
    }
  }
  let hint = Hint.forMismatch(~slice?, m)
  obj->Dict.set("hint", Hint.toJson(hint))
  JSON.Encode.object(obj)
}

let locationJson = (loc: option<Collector.location>): JSON.t =>
  switch loc {
  | None => JSON.Encode.null
  | Some(l) => {
      let d = Dict.make()
      d->Dict.set("file", JSON.Encode.string(l.file))
      d->Dict.set("line", JSON.Encode.int(l.line))
      d->Dict.set("column", JSON.Encode.int(l.column))
      JSON.Encode.object(d)
    }
  }

let testJson = (t: RunnerTypes.testResult): JSON.t => {
  let d = Dict.make()
  d->Dict.set("id", JSON.Encode.string(t.id))
  d->Dict.set("name", JSON.Encode.string(t.name))
  d->Dict.set(
    "describePath",
    t.describePath->Array.map(JSON.Encode.string)->JSON.Encode.array,
  )
  d->Dict.set("status", JSON.Encode.string(RunnerTypes.statusString(t.status)))
  d->Dict.set("durationMs", JSON.Encode.float(t.durationMs))
  d->Dict.set("location", locationJson(t.location))
  switch t.mismatch {
  | Some(m) => d->Dict.set("mismatch", mismatchJson(m, t.slice))
  | None => ()
  }
  switch t.skipReason {
  | Some(r) => d->Dict.set("skipReason", JSON.Encode.string(r))
  | None => ()
  }
  JSON.Encode.object(d)
}

let fileJson = (f: RunnerTypes.fileResult): JSON.t => {
  let d = Dict.make()
  d->Dict.set("path", JSON.Encode.string(f.path))
  d->Dict.set("tests", f.tests->Array.map(testJson)->JSON.Encode.array)
  JSON.Encode.object(d)
}

let summaryJson = (s: RunnerTypes.summary): JSON.t => {
  let d = Dict.make()
  d->Dict.set("total", JSON.Encode.int(s.total))
  d->Dict.set("passed", JSON.Encode.int(s.passed))
  d->Dict.set("failed", JSON.Encode.int(s.failed))
  d->Dict.set("skipped", JSON.Encode.int(s.skipped))
  d->Dict.set("files", JSON.Encode.int(s.files))
  JSON.Encode.object(d)
}

let envelope = (
  r: RunnerTypes.runResult,
  ~toolVersion: string,
  ~schemaVersion: string,
): JSON.t => {
  let d = Dict.make()
  d->Dict.set("schemaVersion", JSON.Encode.string(schemaVersion))
  d->Dict.set("tool", JSON.Encode.string("reventless-gwt"))
  d->Dict.set("toolVersion", JSON.Encode.string(toolVersion))
  d->Dict.set("startedAt", JSON.Encode.string(r.summary.startedAt))
  d->Dict.set("durationMs", JSON.Encode.float(r.summary.durationMs))
  d->Dict.set("summary", summaryJson(r.summary))
  d->Dict.set("files", r.files->Array.map(fileJson)->JSON.Encode.array)
  JSON.Encode.object(d)
}

let emit = (r: RunnerTypes.runResult, ~toolVersion: string, ~schemaVersion=defaultSchemaVersion) =>
  write(JSON.stringify(envelope(r, ~toolVersion, ~schemaVersion), ~space=2) ++ "\n")

// Streaming variant — NDJSON events.
let streamRunStart = (~toolVersion: string, ~startedAt: string, ~schemaVersion=defaultSchemaVersion) => {
  let d = Dict.make()
  d->Dict.set("type", JSON.Encode.string("runStarted"))
  d->Dict.set("schemaVersion", JSON.Encode.string(schemaVersion))
  d->Dict.set("toolVersion", JSON.Encode.string(toolVersion))
  d->Dict.set("at", JSON.Encode.string(startedAt))
  writeLine(JSON.stringify(JSON.Encode.object(d)))
}

let streamFileStart = (path: string) => {
  let d = Dict.make()
  d->Dict.set("type", JSON.Encode.string("fileStarted"))
  d->Dict.set("path", JSON.Encode.string(path))
  writeLine(JSON.stringify(JSON.Encode.object(d)))
}

let streamTest = (t: RunnerTypes.testResult) => {
  let d = Dict.make()
  d->Dict.set("type", JSON.Encode.string("testResult"))
  let tj = testJson(t)
  // Fold testJson's object keys into the envelope.
  switch tj {
  | Object(inner) =>
    inner->Dict.keysToArray->Array.forEach(k =>
      d->Dict.set(k, inner->Dict.getUnsafe(k))
    )
  | _ => ()
  }
  writeLine(JSON.stringify(JSON.Encode.object(d)))
}

let streamFileFinished = (f: RunnerTypes.fileResult) => {
  let passed = ref(0)
  let failed = ref(0)
  f.tests->Array.forEach(t =>
    switch t.status {
    | Pass => passed := passed.contents + 1
    | Fail => failed := failed.contents + 1
    | Skip => ()
    }
  )
  let d = Dict.make()
  d->Dict.set("type", JSON.Encode.string("fileFinished"))
  d->Dict.set("path", JSON.Encode.string(f.path))
  d->Dict.set("passed", JSON.Encode.int(passed.contents))
  d->Dict.set("failed", JSON.Encode.int(failed.contents))
  writeLine(JSON.stringify(JSON.Encode.object(d)))
}

let streamRunEnd = (r: RunnerTypes.runResult) => {
  let d = Dict.make()
  d->Dict.set("type", JSON.Encode.string("runFinished"))
  d->Dict.set("summary", summaryJson(r.summary))
  writeLine(JSON.stringify(JSON.Encode.object(d)))
}
