// Wraps `chokidar` for the `reventless-gwt watch` and `reventless-gwt run
// --watch` modes. Emits one callback per file change event (creates, edits,
// deletes) after a small debounce window so rapid editor saves don't trigger
// overlapping runs.

type watcher
type opts = {
  ignoreInitial: bool,
  ignored: array<string>,
}

@module("chokidar") external watch: (array<string>, opts) => watcher = "watch"
@send external on: (watcher, string, string => unit) => watcher = "on"
@send external close: watcher => promise<unit> = "close"

@val external setTimeout: (unit => unit, int) => float = "setTimeout"
@val external clearTimeout: float => unit = "clearTimeout"

let debounce = (wait: int, fn: string => unit) => {
  let pending: ref<option<float>> = ref(None)
  let lastPath = ref("")
  path => {
    lastPath := path
    switch pending.contents {
    | Some(t) => clearTimeout(t)
    | None => ()
    }
    pending :=
      Some(
        setTimeout(() => {
          pending := None
          fn(lastPath.contents)
        }, wait),
      )
  }
}

let start = (roots: array<string>, onChange: string => unit): watcher => {
  let w = watch(
    roots,
    {
      ignoreInitial: true,
      ignored: ["**/node_modules/**", "**/lib/**", "**/.git/**"],
    },
  )
  let debounced = debounce(120, onChange)
  w->on("add", debounced)->on("change", debounced)->on("unlink", debounced)
}
