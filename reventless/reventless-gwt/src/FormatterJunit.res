// JUnit XML emitter — one `<testsuite>` per file, one `<testcase>` per test.
// Failures carry the human-readable mismatch + hint inside `<failure>` so
// CI tools like Jenkins surface the ReScript-rendered expected/actual in
// their test report UI.

@val external processStdout: {"write": string => unit} = "process.stdout"
let write = (s: string) => processStdout["write"](s)
let writeLine = (s: string) => write(s ++ "\n")

let escapeXml = (s: string) =>
  s
  ->String.replaceAll("&", "&amp;")
  ->String.replaceAll("<", "&lt;")
  ->String.replaceAll(">", "&gt;")
  ->String.replaceAll("\"", "&quot;")
  ->String.replaceAll("'", "&apos;")

let emitFile = (f: RunnerTypes.fileResult) => {
  let tests = f.tests->Array.length
  let failures = ref(0)
  let skipped = ref(0)
  f.tests->Array.forEach(t =>
    switch t.status {
    | Fail => failures := failures.contents + 1
    | Skip => skipped := skipped.contents + 1
    | Pass => ()
    }
  )
  let totalTime = f.tests->Array.reduce(0.0, (a, t) => a +. t.durationMs) /. 1000.0
  writeLine(
    `  <testsuite name="${escapeXml(f.path)}" tests="${Int.toString(
        tests,
      )}" failures="${Int.toString(failures.contents)}" skipped="${Int.toString(
        skipped.contents,
      )}" time="${Float.toString(totalTime)}">`,
  )
  f.tests->Array.forEach(t => {
    let name = t.describePath->Array.join(" > ")
    let classname = name == "" ? f.path : name
    let time = t.durationMs /. 1000.0
    write(
      `    <testcase name="${escapeXml(t.name)}" classname="${escapeXml(
          classname,
        )}" time="${Float.toString(time)}"`,
    )
    switch t.status {
    | Pass => writeLine(" />")
    | Skip => {
        writeLine(">")
        writeLine(
          `      <skipped message="${escapeXml(t.skipReason->Option.getOr("skipped"))}" />`,
        )
        writeLine(`    </testcase>`)
      }
    | Fail => {
        writeLine(">")
        switch t.mismatch {
        | Some(m) => {
            let hint = Hint.forMismatch(~slice=?t.slice, m)
            let msg =
              escapeXml(Outcome.kindName(m)) ++
              ": " ++
              escapeXml(Outcome.format(m)) ++
              "\n\n" ++
              escapeXml(Hint.format(hint))
            writeLine(
              `      <failure type="${escapeXml(Outcome.kindName(m))}" message="${escapeXml(
                  Outcome.format(m),
                )}">${msg}</failure>`,
            )
          }
        | None =>
          writeLine(`      <failure message="failed" type="unknown">failed</failure>`)
        }
        writeLine(`    </testcase>`)
      }
    }
  })
  writeLine(`  </testsuite>`)
}

let emit = (r: RunnerTypes.runResult) => {
  writeLine(`<?xml version="1.0" encoding="UTF-8"?>`)
  writeLine(
    `<testsuites name="reventless-gwt" tests="${Int.toString(
        r.summary.total,
      )}" failures="${Int.toString(r.summary.failed)}" skipped="${Int.toString(
        r.summary.skipped,
      )}" time="${Float.toString(r.summary.durationMs /. 1000.0)}">`,
  )
  r.files->Array.forEach(emitFile)
  writeLine(`</testsuites>`)
}
