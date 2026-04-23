// Dynamic-import wrapper. Each GWT test file registers describe/test at
// import time, so the caller must `Collector.activate()` before invoking
// `loadFile` and drain after. The loader converts the absolute path into
// a `file://` URL so Node's ESM loader accepts it.

@module("node:url") external pathToFileURL: string => {"href": string} = "pathToFileURL"

let dynamicImport: string => promise<'a> = %raw(`(u) => import(u)`)

let loadFile = async (absolutePath: string): unit => {
  let url = pathToFileURL(absolutePath)
  let _: 'a = await dynamicImport(url["href"])
}
