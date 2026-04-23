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
let emitDiscoveryItems = (files: array<(string, array<RunnerTypes.testResult>)>) => {
  files->Array.forEach(((path, tests)) => {
    let fileId = path
    let d = Dict.make()
    d->Dict.set("event", JSON.Encode.string("item"))
    d->Dict.set("id", JSON.Encode.string(fileId))
    d->Dict.set("kind", JSON.Encode.string("file"))
    d->Dict.set("label", JSON.Encode.string(path))
    d->Dict.set("uri", JSON.Encode.string(uriOf(path)))
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
      switch t.location {
      | Some(loc) => {
          leaf->Dict.set("uri", JSON.Encode.string(uriOf(loc.file)))
          leaf->Dict.set("range", rangeJson(loc))
        }
      | None => ()
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
      // Location points at the implementation file (hint.locus) when available;
      // fall back to the test file location.
      switch t.location {
      | Some(loc) => d->Dict.set("location", locationJson(loc))
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
