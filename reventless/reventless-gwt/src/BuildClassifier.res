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
//
// Backstop: a build that prints "Parsed …" but then emits neither a terminator
// nor a recognised error marker — a crashed/hung watcher, or an error in a form
// the markers miss — would otherwise pin the consumer (the VS Code status bar)
// at "building" forever. A generous wall-clock watchdog fails such a build so
// the UI recovers.

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

// Returns a `feed` function: hand it each raw stdout line. `watchdogMs` bounds
// how long a started-but-unterminated compile may stay "building" before it is
// reported failed (see the backstop note above).
let make = (~watchdogMs: int=120_000, cb: callbacks): (string => unit) => {
  let compiling = ref(false)
  let hasError = ref(false)
  let startTime = ref(0.0)
  let buffer = ref([])
  let timer: ref<option<float>> = ref(None)
  let watchdog: ref<option<float>> = ref(None)

  let clearTimer = () =>
    switch timer.contents {
    | Some(t) => {
        clearTimeout(t)
        timer := None
      }
    | None => ()
    }

  let clearWatchdog = () =>
    switch watchdog.contents {
    | Some(t) => {
        clearTimeout(t)
        watchdog := None
      }
    | None => ()
    }

  let reset = () => {
    compiling := false
    hasError := false
    buffer := []
  }

  // After output settles, a compile that saw an error (and thus no "Finished"
  // terminator) is reported failed, capturing a concise message.
  let settle = () =>
    if compiling.contents && hasError.contents {
      let msg = buffer.contents->Array.slice(~start=0, ~end=20)->Array.join("\n")
      clearWatchdog()
      cb.onFail(msg)
      reset()
    }

  let arm = () => {
    clearTimer()
    timer := Some(setTimeout(settle, 400))
  }

  // Last-resort timer: fail a build still compiling after `watchdogMs` with no
  // terminator and no recognised error, so the consumer never spins forever.
  let armWatchdog = () => {
    clearWatchdog()
    watchdog :=
      Some(
        setTimeout(() =>
          if compiling.contents {
            clearTimer()
            cb.onFail("build watchdog: no completion within " ++ Int.toString(watchdogMs / 1000) ++ "s")
            reset()
          }
        , watchdogMs),
      )
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
      armWatchdog()
    } else if isFinishLine(l) {
      clearTimer()
      clearWatchdog()
      if compiling.contents {
        cb.onOk(now() -. startTime.contents)
        reset()
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
