// Loads the frozen plugin-lifecycle payload corpus off disk. See
// tests/fixtures/plugin-lifecycle/README.md.
//
// Reads the directory rather than listing the files here, so adding a fixture is
// a matter of dropping the JSON in — the point of the corpus is that it grows by
// appending real payloads.

type entry = {
  name: string,
  event: string,
  data: dict<JSON.t>,
}

// Resolved against this module rather than the working directory: the suite runs
// from the repo root and from the package, and the fixtures sit beside neither.
// `import.meta.url` is the repo's established way to ask (cf.
// CommandGeneratorFixtures) — a language constant, not reflection.
let moduleUrl: string = %raw(`import.meta.url`)
let dir = NodePath.dirname(NodeUrl.fileURLToPath(moduleUrl)) ++ "/../fixtures/plugin-lifecycle"

let parse = (~name: string, raw: string): option<entry> =>
  raw
  ->JSON.parseOrThrow
  ->JSON.Decode.object
  ->Option.flatMap(obj =>
    switch (
      obj->Dict.get("event")->Option.flatMap(JSON.Decode.string),
      obj->Dict.get("data")->Option.flatMap(JSON.Decode.object),
    ) {
    | (Some(event), Some(data)) => Some({name, event, data})
    | _ => None
    }
  )

// Sorted so the corpus reads in shape-generation order (filenames are
// date-prefixed) and a failure names the same entry on every machine.
let entries: array<entry> =
  NodeFs.readdirSync(dir, {withFileTypes: true})
  ->Array.map(NodeFs.direntName)
  ->Array.filter(name => name->String.endsWith(".json"))
  ->Array.toSorted(String.compare)
  ->Array.filterMap(name => parse(~name, NodeFs.readFileSync(`${dir}/${name}`)))
