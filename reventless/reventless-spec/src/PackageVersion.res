@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"

let fromCwd = () =>
  readFileSync("./package.json", "utf8")
  ->JSON.parseOrThrow
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("version"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("0.0.0")
