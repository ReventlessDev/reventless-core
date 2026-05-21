// TAP 14 emitter with YAML diagnostic blocks on failure. Streamed line-by-line
// so `tap-spec` and GitHub Actions' `actions/test-reporter` can consume the
// output live.

@val external processStdout: {"write": string => unit} = "process.stdout"
let write = (s: string) => processStdout["write"](s)
let writeLine = (s: string) => write(s ++ "\n")

let escapeYamlString = (s: string) =>
  s
  ->String.replaceAll("\\", "\\\\")
  ->String.replaceAll("\"", "\\\"")
  ->String.replaceAll("\n", "\\n")

let yamlString = (s: string) => "\"" ++ escapeYamlString(s) ++ "\""

let yamlLine = (~indent=2, key: string, value: string) =>
  String.repeat(" ", indent) ++ key ++ ": " ++ value

let renderMismatchYaml = (m: Outcome.mismatch) => {
  let lines = []
  lines->Array.push(yamlLine("kind", yamlString(Outcome.kindName(m))))
  switch m {
  | EventsMismatch({expected, actual}) => {
      lines->Array.push(yamlLine("expected", yamlString(RenderRescript.renderMany(expected))))
      lines->Array.push(yamlLine("actual", yamlString(RenderRescript.renderMany(actual))))
    }
  | ErrorMismatch({expected, actual, actualEvents}) => {
      lines->Array.push(
        yamlLine("expected", yamlString("Error(" ++ RenderRescript.render(expected) ++ ")")),
      )
      let actualStr = switch actual {
      | Some(v) => "Error(" ++ RenderRescript.render(v) ++ ")"
      | None => "Ok(" ++ RenderRescript.renderMany(actualEvents) ++ ")"
      }
      lines->Array.push(yamlLine("actual", yamlString(actualStr)))
    }
  | StateMismatch({key, expected, actual}) => {
      lines->Array.push(yamlLine("key", yamlString(key)))
      lines->Array.push(yamlLine("expected", yamlString(RenderRescript.renderOption(expected))))
      lines->Array.push(yamlLine("actual", yamlString(RenderRescript.renderOption(actual))))
    }
  | NoEventExpected({actual}) =>
    lines->Array.push(yamlLine("actual", yamlString(RenderRescript.renderMany(actual))))
  | TodoMismatch({expected, actual}) => {
      let fmt = arr =>
        arr
        ->Array.map(((id, v)) => "(" ++ id ++ ", " ++ RenderRescript.render(v) ++ ")")
        ->Array.join(", ")
      lines->Array.push(yamlLine("expected", yamlString("[" ++ fmt(expected) ++ "]")))
      lines->Array.push(yamlLine("actual", yamlString("[" ++ fmt(actual) ++ "]")))
    }
  | AppendConditionMismatch({expected, actual}) => {
      lines->Array.push(yamlLine("expected", yamlString(RenderRescript.render(expected))))
      lines->Array.push(yamlLine("actual", yamlString(RenderRescript.render(actual))))
    }
  | TranslateError({expected, actual}) => {
      lines->Array.push(yamlLine("expected", yamlString(expected)))
      lines->Array.push(yamlLine("actual", yamlString(actual->Option.getOr("(none)"))))
    }
  | QueryRowsMismatch({expected, actual}) => {
      lines->Array.push(yamlLine("expected", yamlString(RenderRescript.renderMany(expected))))
      lines->Array.push(yamlLine("actual", yamlString(RenderRescript.renderMany(actual))))
    }
  | PublishedActionsMismatch({expected, actual}) => {
      lines->Array.push(yamlLine("expected", yamlString(RenderRescript.renderMany(expected))))
      lines->Array.push(yamlLine("actual", yamlString(RenderRescript.renderMany(actual))))
    }
  | Throw({error, stack}) => {
      lines->Array.push(yamlLine("error", yamlString(error)))
      lines->Array.push(yamlLine("stack", yamlString(stack)))
    }
  }
  lines->Array.join("\n")
}

let emit = (r: RunnerTypes.runResult) => {
  writeLine("TAP version 14")
  writeLine(`1..${Int.toString(r.summary.total)}`)
  let index = ref(0)
  r.files->Array.forEach(f => {
    writeLine("")
    writeLine(`# ${f.path}`)
    f.tests->Array.forEach(t => {
      index := index.contents + 1
      let n = index.contents
      let path = t.describePath->Array.join(" > ")
      let title = path == "" ? t.name : `${path} > ${t.name}`
      let ms = ` # time=${Float.toString(t.durationMs)}ms`
      switch t.status {
      | Pass => writeLine(`ok ${Int.toString(n)} - ${title}${ms}`)
      | Skip => {
          let reason = t.skipReason->Option.getOr("skipped")
          writeLine(`ok ${Int.toString(n)} - ${title} # SKIP ${reason}`)
        }
      | Fail => {
          writeLine(`not ok ${Int.toString(n)} - ${title}${ms}`)
          writeLine("  ---")
          switch t.location {
          | Some(loc) =>
            writeLine(
              yamlLine(
                "location",
                `{ file: "${loc.file}", line: ${Int.toString(loc.line)} }`,
              ),
            )
          | None => ()
          }
          switch t.mismatch {
          | Some(m) => writeLine(renderMismatchYaml(m))
          | None => ()
          }
          switch t.mismatch {
          | Some(m) => {
              let hint = Hint.forMismatch(~slice=?t.slice, m)
              writeLine(yamlLine("hint", ""))
              writeLine(yamlLine(~indent=4, "locus", yamlString(hint.locus)))
              writeLine(
                yamlLine(
                  ~indent=4,
                  "branch",
                  yamlString(hint.branch->Option.getOr("(none)")),
                ),
              )
              writeLine(yamlLine(~indent=4, "message", yamlString(hint.message)))
            }
          | None => ()
          }
          writeLine("  ...")
        }
      }
    })
  })
  writeLine("")
  writeLine(`# tests ${Int.toString(r.summary.total)}`)
  writeLine(`# pass ${Int.toString(r.summary.passed)}`)
  writeLine(`# fail ${Int.toString(r.summary.failed)}`)
  writeLine(`# skip ${Int.toString(r.summary.skipped)}`)
}
