// Terminal-coloured human formatter. Shipped as the default output for
// `reventless-gwt run`. Uses picocolors for ANSI colours — it is a tiny
// zero-dependency helper that transparently disables colour when stdout
// is not a TTY.

type colour = string => string
type picocolors = {
  red: colour,
  green: colour,
  yellow: colour,
  cyan: colour,
  gray: colour,
  bold: colour,
  dim: colour,
}

@module("picocolors") external pc: picocolors = "default"

@val external processStdout: {"write": string => unit} = "process.stdout"
@val external processCwd: unit => string = "process.cwd"
@module("node:path") external pathBasename: string => string = "basename"
@module("node:path") external pathRelative: (string, string) => string = "relative"

let write = (s: string) => processStdout["write"](s)
let writeLine = (s: string) => write(s ++ "\n")

let formatFilePath = (abs: string) => {
  let base = pathBasename(abs)
  let name = if String.endsWith(base, ".res.mjs") {
    String.slice(base, ~start=0, ~end=String.length(base) - 8)
  } else {
    base
  }
  let rel = pathRelative(processCwd(), abs)
  `${name} - ${rel}`
}

let formatLocation = (loc: option<Collector.location>) =>
  switch loc {
  | None => ""
  | Some(l) => `${l.file}:${Int.toString(l.line)}`
  }

let renderMismatch = (m: Outcome.mismatch) =>
  switch m {
  | EventsMismatch({expected, actual}) => {
      let exp = RenderRescript.renderMany(expected)
      let act = RenderRescript.renderMany(actual)
      `  expected: ${exp}\n  actual:   ${act}`
    }
  | ErrorMismatch({expected, actual, actualEvents}) => {
      let exp = `Error(${RenderRescript.render(expected)})`
      let act = switch actual {
      | Some(v) => `Error(${RenderRescript.render(v)})`
      | None => `Ok(${RenderRescript.renderMany(actualEvents)})`
      }
      `  expected: ${exp}\n  actual:   ${act}`
    }
  | StateMismatch({key, expected, actual}) =>
    `  key:      "${key}"\n  expected: ${RenderRescript.renderOption(
        expected,
      )}\n  actual:   ${RenderRescript.renderOption(actual)}`
  | NoEventExpected({actual}) =>
    `  expected no events\n  actual:   ${RenderRescript.renderMany(actual)}`
  | TodoMismatch({expected, actual}) => {
      let fmt = (arr: array<(string, JSON.t)>) =>
        arr
        ->Array.map(((id, v)) => `(${id}, ${RenderRescript.render(v)})`)
        ->Array.join(", ")
      `  expected: [${fmt(expected)}]\n  actual:   [${fmt(actual)}]`
    }
  | AppendConditionMismatch({expected, actual}) =>
    `  expected: ${RenderRescript.render(expected)}\n  actual:   ${RenderRescript.render(
        actual,
      )}`
  | TranslateError({expected, actual}) =>
    `  expected: ${expected}\n  actual:   ${actual->Option.getOr("(none)")}`
  | QueryRowsMismatch({expected, actual}) =>
    `  expected: ${RenderRescript.renderMany(expected)}\n  actual:   ${RenderRescript.renderMany(
        actual,
      )}`
  | Throw({error, stack}) => `  error: ${error}\n${stack}`
  }

let emitTest = (t: RunnerTypes.testResult) => {
  let path = t.describePath->Array.join(" > ")
  let full = path == "" ? t.name : `${path} > ${t.name}`
  let loc = formatLocation(t.location)
  let locStr = loc == "" ? "" : ` ${pc.dim(loc)}`
  switch t.status {
  | Pass => writeLine(`  ${pc.green("✓")} ${full}${locStr}`)
  | Skip =>
    writeLine(
      `  ${pc.yellow("○")} ${full}${locStr} ${pc.dim(
          t.skipReason->Option.getOr("skipped"),
        )}`,
    )
  | Fail => {
      writeLine(`  ${pc.red("✗")} ${pc.bold(full)}${locStr}`)
      switch t.mismatch {
      | Some(m) => {
          writeLine("")
          writeLine(renderMismatch(m))
          let hint = Hint.forMismatch(~slice=?t.slice, m)
          writeLine("")
          writeLine(`  ${pc.cyan(Hint.format(hint))}`)
          writeLine("")
        }
      | None => ()
      }
    }
  }
}

let emitFile = (f: RunnerTypes.fileResult) => {
  writeLine("")
  writeLine(pc.bold(formatFilePath(f.path)))
  f.tests->Array.forEach(emitTest)
}

let emitSummary = (s: RunnerTypes.summary) => {
  writeLine("")
  let line = `Tests: ${Int.toString(s.total)}  ${pc.green(
      Int.toString(s.passed) ++ " passed",
    )}  ${pc.red(Int.toString(s.failed) ++ " failed")}  ${pc.yellow(
      Int.toString(s.skipped) ++ " skipped",
    )}  (${Float.toString(s.durationMs)} ms)`
  writeLine(line)
}

let emit = (r: RunnerTypes.runResult) => {
  r.files->Array.forEach(emitFile)
  emitSummary(r.summary)
}
