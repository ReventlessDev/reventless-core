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

// Rank events so a coalesced burst reports the *strongest structural* signal
// with a representative path. A single directory `mv` emits an interleaved
// burst — `unlink` of the `.res` AND the generated `.res.mjs`, then `add`s at
// the new path — inside one debounce window. The representative path must be a
// `.res` *source* unlink (the relocation signal), never a `.res.mjs` or a
// trailing add, or the consumer misclassifies it as an ordinary change. So an
// unlink of a `.res` source outranks everything; any other unlink/add outranks
// a plain edit.
let rank = (event: event, path: string): int =>
  switch event {
  | Unlink => String.endsWith(path, ".res") ? 2 : 1
  | Add => 1
  | Change => 0
  }

// True when an event is the *structural* signal Phase 12 acts on: a source
// `.res` file leaving a directory (the move/delete half of a relocation).
// Generated `.res.mjs` outputs end in `.mjs`, so they never match — which is
// also what keeps a `rescript clean` (it deletes those outputs) from
// re-triggering the clean-rebuild it just ran.
let isStructuralSource = (event: event, path: string): bool =>
  event == Unlink && String.endsWith(path, ".res")

let debounce = (wait: int, fn: (event, string) => unit) => {
  let pending: ref<option<float>> = ref(None)
  let bestRank = ref(-1)
  let bestEvent = ref(Change)
  let bestPath = ref("")
  (event, path) => {
    let r = rank(event, path)
    if r >= bestRank.contents {
      bestRank := r
      bestEvent := event
      bestPath := path
    }
    switch pending.contents {
    | Some(t) => clearTimeout(t)
    | None => ()
    }
    pending :=
      Some(
        setTimeout(() => {
          pending := None
          let e = bestEvent.contents
          let p = bestPath.contents
          bestRank := -1
          bestEvent := Change
          bestPath := ""
          fn(e, p)
        }, wait),
      )
  }
}

let start = (roots: array<string>, onChange: (event, string) => unit): watcher => {
  let w = watch(
    roots,
    {
      ignoreInitial: true,
      ignored: ["**/node_modules/**", "**/lib/**", "**/.git/**"],
    },
  )
  let debounced = debounce(120, onChange)
  w
  ->on("add", p => debounced(Add, p))
  ->on("change", p => debounced(Change, p))
  ->on("unlink", p => debounced(Unlink, p))
}
