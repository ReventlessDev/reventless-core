// Turns a ReScript v12 `rescript build -w` stdout line-stream into build status
// callbacks. One classifier per managed package.
//
// The watch output cycle is:
//   Parsed N source files          ← a compile pass begins
//   Compiled N modules
//   Finished incremental compilation   ← success terminator
// On a type/syntax error there is NO terminator — rescript prints a
// "We've found a bug for you!" block and waits. So success is detected on the
// "Finished … compilation" line; failure is detected by an error marker and
// flushed after the output settles (debounced), since there is no end line.

@val external now: unit => float = "performance.now"
@val external setTimeout: (unit => unit, int) => float = "setTimeout"
@val external clearTimeout: float => unit = "clearTimeout"

let stripAnsi: string => string = %raw(`s => s.replace(/\x1b\[[0-9;]*m/g, "")`)

type callbacks = {
  onStart: unit => unit,
  onOk: float => unit,
  onFail: string => unit,
}

let isStartLine = (l: string) =>
  String.startsWith(l, "Parsed ") && String.endsWith(l, "source files")

let isFinishLine = (l: string) =>
  String.includes(l, "Finished") && String.includes(l, "compilation")

let isErrorMarker = (l: string) =>
  String.includes(l, "We've found a bug for you!") ||
  String.includes(l, "Syntax error") ||
  (String.startsWith(l, "Found ") && String.includes(l, "error"))

// Returns a `feed` function: hand it each raw stdout line.
let make = (cb: callbacks): (string => unit) => {
  let compiling = ref(false)
  let hasError = ref(false)
  let startTime = ref(0.0)
  let buffer = ref([])
  let timer: ref<option<float>> = ref(None)

  let clearTimer = () =>
    switch timer.contents {
    | Some(t) => {
        clearTimeout(t)
        timer := None
      }
    | None => ()
    }

  // After output settles, a compile that saw an error (and thus no "Finished"
  // terminator) is reported failed, capturing a concise message.
  let settle = () =>
    if compiling.contents && hasError.contents {
      let msg = buffer.contents->Array.slice(~start=0, ~end=20)->Array.join("\n")
      cb.onFail(msg)
      compiling := false
      hasError := false
      buffer := []
    }

  let arm = () => {
    clearTimer()
    timer := Some(setTimeout(settle, 400))
  }

  line => {
    let l = stripAnsi(line)->String.trim
    if isStartLine(l) {
      if !compiling.contents {
        cb.onStart()
      }
      compiling := true
      hasError := false
      buffer := []
      startTime := now()
      arm()
    } else if isFinishLine(l) {
      clearTimer()
      if compiling.contents {
        cb.onOk(now() -. startTime.contents)
        compiling := false
        hasError := false
        buffer := []
      }
    } else {
      if String.length(l) > 0 {
        buffer := Array.concat(buffer.contents, [l])
      }
      if isErrorMarker(l) {
        hasError := true
      }
      arm()
    }
  }
}
