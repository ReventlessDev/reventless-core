// Wraps `chokidar` for the `reventless-gwt watch` and `reventless-gwt run
// --watch` modes. Emits one callback per file change event (creates, edits,
// deletes) after a small debounce window so rapid editor saves don't trigger
// overlapping runs.

type watcher
type opts = {
  ignoreInitial: bool,
  ignored: array<string>,
}

// The kind of filesystem change, threaded through so the consumer can tell a
// *structural* change (a source file appearing/disappearing — the move/delete
// half of a relocation) from a plain edit. Phase 12 keys its clean-rebuild on
// an `Unlink` of a `.res` source.
type event = Add | Change | Unlink

@module("chokidar") external watch: (array<string>, opts) => watcher = "watch"
@send external on: (watcher, string, string => unit) => watcher = "on"
@send external close: watcher => promise<unit> = "close"

@val external setTimeout: (unit => unit, int) => float = "setTimeout"
@val external clearTimeout: float => unit = "clearTimeout"

// True when an event is the *structural* signal Phase 12 acts on: a source
// `.res` file leaving a directory (the move/delete half of a relocation).
// Generated `.res.mjs` outputs end in `.mjs`, so they never match — which is
// also what keeps a `rescript clean` (it deletes those outputs) from
// re-triggering the clean-rebuild it just ran.
let isStructuralSource = (event: event, path: string): bool =>
  event == Unlink && String.endsWith(path, ".res")

// Coalesce a burst of chokidar events into a single debounce window, then emit.
// A window may span *multiple* packages — a branch switch or a multi-package
// refactor emits `.res` unlinks under several package roots at once. The old
// shape kept only one "best" path, so it clean-rebuilt just one package and
// left the others with stale `.res.mjs`. Instead accumulate the *set* of
// distinct structural source paths and emit one `Unlink` callback per path
// (the consumer maps each to its owning package). If the window held no
// structural signal, emit a single representative event so the consumer does a
// plain re-run.
let debounce = (wait: int, fn: (event, string) => unit) => {
  let pending: ref<option<float>> = ref(None)
  let structural: ref<array<string>> = ref([])
  let sawOther = ref(false)
  let otherEvent = ref(Change)
  let otherPath = ref("")
  (event, path) => {
    if isStructuralSource(event, path) {
      if !(structural.contents->Array.includes(path)) {
        structural := Array.concat(structural.contents, [path])
      }
    } else {
      sawOther := true
      otherEvent := event
      otherPath := path
    }
    switch pending.contents {
    | Some(t) => clearTimeout(t)
    | None => ()
    }
    pending :=
      Some(
        setTimeout(() => {
          pending := None
          let paths = structural.contents
          let other = sawOther.contents
          let oe = otherEvent.contents
          let op = otherPath.contents
          structural := []
          sawOther := false
          otherEvent := Change
          otherPath := ""
          if paths->Array.length > 0 {
            // One rebuild per distinct owning package; a plain edit alongside
            // is covered by each structural rebuild's own re-run.
            paths->Array.forEach(p => fn(Unlink, p))
          } else if other {
            fn(oe, op)
          }
        }, wait),
      )
  }
}

let start = (roots: array<string>, onChange: (event, string) => unit): watcher => {
  let w = watch(
    roots,
    {
      ignoreInitial: true,
      // Shared with the scanners via `ScanIgnore` — writes under `dist/` or
      // `.history/` are build/editor output, not source, and a `dist/` write
      // could otherwise drive a re-run loop.
      ignored: ScanIgnore.globs,
    },
  )
  let debounced = debounce(120, onChange)
  w
  ->on("add", p => debounced(Add, p))
  ->on("change", p => debounced(Change, p))
  ->on("unlink", p => debounced(Unlink, p))
}
