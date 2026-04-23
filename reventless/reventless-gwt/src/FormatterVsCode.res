// NDJSON event stream tailored for the VS Code Testing API. Each line maps
// directly to a `TestRun` method call; field names mirror `TestItem` /
// `TestMessage` so the extension needs no translation layer. See §3.3 of the
// analysis doc for the event table.

@val external processStdout: {"write": string => unit} = "process.stdout"
let write = (s: string) => processStdout["write"](s)
let writeLine = (s: string) => write(s ++ "\n")

let setIfSome = (d: Dict.t<JSON.t>, k: string, o: option<JSON.t>) =>
  switch o {
  | Some(v) => d->Dict.set(k, v)
  | None => ()
  }

let uriOf = (path: string) => "file://" ++ path

// ─── .res-source locator ───────────────────────────────────────────────────
// ReScript v12 does not emit JS source maps, so V8 stack frames (the basis for
// Collector.captureLocation) point at `.res.mjs`. Every GWT combinator
// (`test`, `describe`, `given`, …) takes a string literal as its first
// argument — scanning the sibling `.res` file for that literal yields an
// exact line. This turns the Testing panel's tree-node clicks into
// `.res` jumps instead of compiled-output jumps.

@module("node:fs") external _readFileSync: (string, string) => string = "readFileSync"
@module("node:fs") external _existsSync: string => bool = "existsSync"

let sourceLineCache: Dict.t<option<array<string>>> = Dict.make()

let resetLocateCache = () => {
  sourceLineCache
  ->Dict.keysToArray
  ->Array.forEach(k => Dict.delete(sourceLineCache, k))
}

let mjsToRes = (mjsPath: string): option<string> =>
  if String.endsWith(mjsPath, ".res.mjs") {
    Some(String.slice(mjsPath, ~start=0, ~end=String.length(mjsPath) - 4))
  } else {
    None
  }

let readLinesCached = (resPath: string): option<array<string>> =>
  switch sourceLineCache->Dict.get(resPath) {
  | Some(v) => v
  | None => {
      let v = try {
        _existsSync(resPath)
          ? Some(_readFileSync(resPath, "utf8")->String.split("\n"))
          : None
      } catch {
      | _ => None
      }
      sourceLineCache->Dict.set(resPath, v)
      v
    }
  }

let escapeForDouble = (s: string) =>
  s->String.replaceAll("\\", "\\\\")->String.replaceAll("\"", "\\\"")

let escapeForSingle = (s: string) =>
  s->String.replaceAll("\\", "\\\\")->String.replaceAll("'", "\\'")

let locateInSource = (mjsPath: string, label: string): option<Collector.location> =>
  switch mjsToRes(mjsPath) {
  | None => None
  | Some(resPath) =>
    switch readLinesCached(resPath) {
    | None => None
    | Some(lines) => {
        let needleD = "\"" ++ escapeForDouble(label) ++ "\""
        let needleS = "'" ++ escapeForSingle(label) ++ "'"
        let total = lines->Array.length
        let rec find = i =>
          if i >= total {
            None
          } else {
            let line = lines->Array.getUnsafe(i)
            let idxD = String.indexOf(line, needleD)
            let idxS = String.indexOf(line, needleS)
            let col = switch (idxD, idxS) {
            | (-1, -1) => -1
            | (-1, c) => c + 1
            | (c, -1) => c + 1
            | (a, b) => (a < b ? a : b) + 1
            }
            if col < 0 {
              find(i + 1)
            } else {
              Some({Collector.file: resPath, line: i + 1, column: col})
            }
          }
        find(0)
      }
    }
  }

let rangeJson = (loc: Collector.location): JSON.t => {
  let start = Dict.make()
  start->Dict.set("line", JSON.Encode.int(loc.line - 1))
  start->Dict.set("character", JSON.Encode.int(loc.column - 1))
  let end_ = Dict.make()
  end_->Dict.set("line", JSON.Encode.int(loc.line - 1))
  end_->Dict.set("character", JSON.Encode.int(loc.column - 1))
  let r = Dict.make()
  r->Dict.set("start", JSON.Encode.object(start))
  r->Dict.set("end", JSON.Encode.object(end_))
  JSON.Encode.object(r)
}

let locationJson = (loc: Collector.location): JSON.t => {
  let d = Dict.make()
  d->Dict.set("uri", JSON.Encode.string(uriOf(loc.file)))
  d->Dict.set("range", rangeJson(loc))
  JSON.Encode.object(d)
}

let event = (payload: Dict.t<JSON.t>) => writeLine(JSON.stringify(JSON.Encode.object(payload)))

let discoverStart = () => {
  let d = Dict.make()
  d->Dict.set("event", JSON.Encode.string("discoverStart"))
  event(d)
}

// Used in both `discover` and `run` flows — emit one `item` per file, one
// per describe, one per test so the tree populates before any test runs.
// File / suite / test URIs point at `.res` sources whenever the sibling
// `.res` is readable — `locateInSource` grep-scans for the quoted label.
// Falls back to `.res.mjs` when no `.res` is adjacent (e.g. a hand-written
// `.mjs` or a renamed build output) so nothing regresses for downstream users.
let emitDiscoveryItems = (files: array<(string, array<RunnerTypes.testResult>)>) => {
  files->Array.forEach(((path, tests)) => {
    let fileId = path
    let fileUri = switch mjsToRes(path) {
    | Some(resPath) if _existsSync(resPath) => uriOf(resPath)
    | _ => uriOf(path)
    }
    let d = Dict.make()
    d->Dict.set("event", JSON.Encode.string("item"))
    d->Dict.set("id", JSON.Encode.string(fileId))
    d->Dict.set("kind", JSON.Encode.string("file"))
    d->Dict.set("label", JSON.Encode.string(path))
    d->Dict.set("uri", JSON.Encode.string(fileUri))
    event(d)
    // Emit describe suites and test leaves.
    let seenDescribes = Dict.make()
    tests->Array.forEach(t => {
      // Emit nested describe chain as `suite` items.
      let stack = ref([])
      t.describePath->Array.forEach(label => {
        let parent =
          stack.contents->Array.length == 0
            ? fileId
            : fileId ++ "::" ++ stack.contents->Array.join("::")
        stack := Array.concat(stack.contents, [label])
        let id = fileId ++ "::" ++ stack.contents->Array.join("::")
        switch seenDescribes->Dict.get(id) {
        | Some(_) => ()
        | None => {
            seenDescribes->Dict.set(id, true)
            let s = Dict.make()
            s->Dict.set("event", JSON.Encode.string("item"))
            s->Dict.set("id", JSON.Encode.string(id))
            s->Dict.set("parent", JSON.Encode.string(parent))
            s->Dict.set("kind", JSON.Encode.string("suite"))
            s->Dict.set("label", JSON.Encode.string(label))
            switch locateInSource(path, label) {
            | Some(loc) => {
                s->Dict.set("uri", JSON.Encode.string(uriOf(loc.file)))
                s->Dict.set("range", rangeJson(loc))
              }
            | None => ()
            }
            event(s)
          }
        }
      })
      let parent =
        t.describePath->Array.length == 0
          ? fileId
          : fileId ++ "::" ++ t.describePath->Array.join("::")
      let testId = fileId ++ "::" ++ t.id
      let leaf = Dict.make()
      leaf->Dict.set("event", JSON.Encode.string("item"))
      leaf->Dict.set("id", JSON.Encode.string(testId))
      leaf->Dict.set("parent", JSON.Encode.string(parent))
      leaf->Dict.set("kind", JSON.Encode.string("test"))
      leaf->Dict.set("label", JSON.Encode.string(t.name))
      let resLoc = locateInSource(path, t.name)
      switch (resLoc, t.location) {
      | (Some(loc), _) | (None, Some(loc)) => {
          leaf->Dict.set("uri", JSON.Encode.string(uriOf(loc.file)))
          leaf->Dict.set("range", rangeJson(loc))
        }
      | (None, None) => ()
      }
      event(leaf)
    })
  })
}

let discoverEnd = (total: int) => {
  let d = Dict.make()
  d->Dict.set("event", JSON.Encode.string("discoverEnd"))
  d->Dict.set("total", JSON.Encode.int(total))
  event(d)
}

let runStart = (~total: int, ~filter: array<string>) => {
  let d = Dict.make()
  d->Dict.set("event", JSON.Encode.string("runStart"))
  d->Dict.set("total", JSON.Encode.int(total))
  d->Dict.set("filter", filter->Array.map(JSON.Encode.string)->JSON.Encode.array)
  event(d)
}

let testStart = (id: string) => {
  let d = Dict.make()
  d->Dict.set("event", JSON.Encode.string("testStart"))
  d->Dict.set("id", JSON.Encode.string(id))
  event(d)
}

let testPass = (id: string, durationMs: float) => {
  let d = Dict.make()
  d->Dict.set("event", JSON.Encode.string("testPass"))
  d->Dict.set("id", JSON.Encode.string(id))
  d->Dict.set("durationMs", JSON.Encode.float(durationMs))
  event(d)
}

let testSkip = (id: string, reason: string) => {
  let d = Dict.make()
  d->Dict.set("event", JSON.Encode.string("testSkip"))
  d->Dict.set("id", JSON.Encode.string(id))
  d->Dict.set("reason", JSON.Encode.string(reason))
  event(d)
}

let messagePayload = (t: RunnerTypes.testResult): JSON.t => {
  let d = Dict.make()
  switch t.mismatch {
  | Some(m) => {
      let hint = Hint.forMismatch(~slice=?t.slice, m)
      d->Dict.set("message", JSON.Encode.string(hint.message))
      // Expected / actual for the diff view. Rendered as ReScript syntax.
      switch m {
      | EventsMismatch({expected, actual}) => {
          d->Dict.set(
            "expected",
            JSON.Encode.string(RenderRescript.renderMany(expected)),
          )
          d->Dict.set("actual", JSON.Encode.string(RenderRescript.renderMany(actual)))
        }
      | ErrorMismatch({expected, actual, actualEvents}) => {
          d->Dict.set(
            "expected",
            JSON.Encode.string("Error(" ++ RenderRescript.render(expected) ++ ")"),
          )
          let actStr = switch actual {
          | Some(v) => "Error(" ++ RenderRescript.render(v) ++ ")"
          | None => "Ok(" ++ RenderRescript.renderMany(actualEvents) ++ ")"
          }
          d->Dict.set("actual", JSON.Encode.string(actStr))
        }
      | StateMismatch({expected, actual, _}) => {
          d->Dict.set("expected", JSON.Encode.string(RenderRescript.renderOption(expected)))
          d->Dict.set("actual", JSON.Encode.string(RenderRescript.renderOption(actual)))
        }
      | NoEventExpected({actual}) => {
          d->Dict.set("expected", JSON.Encode.string("[]"))
          d->Dict.set("actual", JSON.Encode.string(RenderRescript.renderMany(actual)))
        }
      | QueryRowsMismatch({expected, actual}) => {
          d->Dict.set("expected", JSON.Encode.string(RenderRescript.renderMany(expected)))
          d->Dict.set("actual", JSON.Encode.string(RenderRescript.renderMany(actual)))
        }
      | AppendConditionMismatch({expected, actual}) => {
          d->Dict.set("expected", JSON.Encode.string(RenderRescript.render(expected)))
          d->Dict.set("actual", JSON.Encode.string(RenderRescript.render(actual)))
        }
      | TranslateError({expected, actual}) => {
          d->Dict.set("expected", JSON.Encode.string(expected))
          d->Dict.set("actual", JSON.Encode.string(actual->Option.getOr("(none)")))
        }
      | TodoMismatch(_) => {
          d->Dict.set("expected", JSON.Encode.string(Outcome.format(m)))
          d->Dict.set("actual", JSON.Encode.string(""))
        }
      | Throw({error}) => {
          d->Dict.set("expected", JSON.Encode.string(""))
          d->Dict.set("actual", JSON.Encode.string(error))
        }
      }
      // Location points at the test file — prefer the sibling `.res` path
      // resolved via the test label so Cmd+Click on the failure header
      // jumps to the readable source, not the compiled `.res.mjs`.
      switch t.location {
      | Some(loc) =>
        let resLoc = locateInSource(loc.file, t.name)
        d->Dict.set("location", locationJson(resLoc->Option.getOr(loc)))
      | None => ()
      }
    }
  | None => d->Dict.set("message", JSON.Encode.string("failed"))
  }
  JSON.Encode.object(d)
}

let testFail = (t: RunnerTypes.testResult, id: string) => {
  let d = Dict.make()
  d->Dict.set("event", JSON.Encode.string("testFail"))
  d->Dict.set("id", JSON.Encode.string(id))
  d->Dict.set("durationMs", JSON.Encode.float(t.durationMs))
  d->Dict.set("messages", JSON.Encode.array([messagePayload(t)]))
  event(d)
}

let runEnd = (s: RunnerTypes.summary) => {
  let d = Dict.make()
  d->Dict.set("event", JSON.Encode.string("runEnd"))
  d->Dict.set("passed", JSON.Encode.int(s.passed))
  d->Dict.set("failed", JSON.Encode.int(s.failed))
  d->Dict.set("skipped", JSON.Encode.int(s.skipped))
  d->Dict.set("durationMs", JSON.Encode.float(s.durationMs))
  event(d)
}
