@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external dirname: string => string = "dirname"
@module("node:path") external join: (string, string) => string = "join"

let readVersion = (path: string) =>
  readFileSync(path, "utf8")
  ->JSON.parseOrThrow
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("version"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("0.0.0")

let fromCwd = () => readVersion("./package.json")

let findVersion = dir => {
  let rec find = dir => {
    let candidate = join(dir, "package.json")
    if existsSync(candidate) {
      readVersion(candidate)
    } else {
      let parent = dirname(dir)
      if parent == dir {
        "0.0.0"
      } else {
        find(parent)
      }
    }
  }
  find(dir)
}

let fromModuleUrl = (url: string) => findVersion(url->fileURLToPath->dirname)

/** Detect the caller's file via V8 Structured Stack Trace API and read the
    version from the nearest package.json. Skips frames from framework packages
    (reventless-spec, reventless-core, reventless-infra, reventless-local,
    reventless-aws, reventless-interop). Falls back to CWD's package.json. */
let callerFile: unit => option<string> = %raw(`
  function() {
    var frameworkMarkers = [
      '/reventless/',
      '/@reventlessdev/reventless-',
    ];
    var oldPrepare = Error.prepareStackTrace;
    Error.prepareStackTrace = function(_, stack) { return stack; };
    var err = new Error();
    var stack = err.stack;
    Error.prepareStackTrace = oldPrepare;
    for (var i = 0; i < stack.length; i++) {
      var file = stack[i].getFileName();
      if (!file) continue;
      var isFramework = false;
      for (var j = 0; j < frameworkMarkers.length; j++) {
        if (file.indexOf(frameworkMarkers[j]) !== -1) { isFramework = true; break; }
      }
      if (!isFramework) return file;
    }
    return undefined;
  }
`)

let fromCaller = () =>
  switch callerFile() {
  | Some(file) =>
    if file->String.startsWith("file://") {
      findVersion(file->fileURLToPath->dirname)
    } else {
      findVersion(file->dirname)
    }
  | None => fromCwd()
  }
