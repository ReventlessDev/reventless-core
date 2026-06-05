// Dynamic-import wrapper. Each GWT test file registers describe/test at
// import time, so the caller must `Collector.activate()` before invoking
// `loadFile` and drain after. The loader converts the absolute path into
// a `file://` URL so Node's ESM loader accepts it.
//
// A monotonic cache-busting query (`?t=N`) is appended so every load
// re-executes the module's top-level registration. Node's ESM cache is keyed
// by URL (not mtime), so without this a second load in the same process — the
// `discover`-then-run within `watch`, and every re-run after a recompile —
// would hit the cache, skip registration, and drain zero tests. The `?t=`
// query is stripped from captured stack frames in `Collector.parseFrame`.

@module("node:url") external pathToFileURL: string => {"href": string} = "pathToFileURL"

let dynamicImport: string => promise<'a> = %raw(`(u) => import(u)`)

let counter = ref(0)

let loadFile = async (absolutePath: string): unit => {
  counter := counter.contents + 1
  let url = pathToFileURL(absolutePath)
  let busted = url["href"] ++ "?t=" ++ Int.toString(counter.contents)
  let _: 'a = await dynamicImport(busted)
}
