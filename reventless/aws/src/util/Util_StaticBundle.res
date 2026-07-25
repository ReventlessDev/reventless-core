let log = ReventlessCore.Logger.fromEnv()

@module("path") external join2: (string, string) => string = "join"
@module("path") external relative: (string, string) => string = "relative"

@module("fs") external existsSync: string => bool = "existsSync"
@module("fs") external readFileSync: string => Js.TypedArray2.Uint8Array.t = "readFileSync"
@module("fs") external readFileSyncUtf8: (string, string) => string = "readFileSync"
type dirent
@module("fs")
external readdirSync: (string, {"withFileTypes": bool}) => array<dirent> = "readdirSync"
@send external isDirectory: dirent => bool = "isDirectory"
@get external direntName: dirent => string = "name"

type hashObj
@module("crypto") external createHash: string => hashObj = "createHash"
@send external updateBuffer: (hashObj, Js.TypedArray2.Uint8Array.t) => hashObj = "update"
@send external digest: (hashObj, string) => string = "digest"

type fileEntry = {
  relativePath: string,
  absolutePath: string,
  fileAsset: Pulumi.Asset.t,
  contentHash: string,
}

let toForwardSlashes = (p: string): string => p->String.replaceAll("\\", "/")

let isHidden = (name: string): bool => name->String.startsWith(".")

let rec walkInto = (~dir: string, ~prefix: string, acc: array<fileEntry>): unit => {
  let entries = readdirSync(dir, {"withFileTypes": true})
  entries->Array.forEach(entry => {
    let entryName = entry->direntName
    if isHidden(entryName) {
      ()
    } else if entry->isDirectory {
      let nextPrefix = prefix == "" ? entryName : prefix ++ "/" ++ entryName
      walkInto(~dir=join2(dir, entryName), ~prefix=nextPrefix, acc)
    } else {
      let absolutePath = join2(dir, entryName)
      let relativePath = prefix == "" ? entryName : prefix ++ "/" ++ entryName
      let bytes = readFileSync(absolutePath)
      let contentHash =
        createHash("sha256")
        ->updateBuffer(bytes)
        ->digest("hex")
      acc->Array.push({
        relativePath: relativePath->toForwardSlashes,
        absolutePath,
        fileAsset: Pulumi.Asset.fileAsset(absolutePath),
        contentHash,
      })
    }
  })
}

/**
 * Walk a directory recursively and return one entry per file with its
 * relative S3 key, content hash, and a Pulumi FileAsset. Skips dotfiles.
 */
let walk = (assetsDir: string): array<fileEntry> => {
  if !existsSync(assetsDir) {
    JsError.throwWithMessage(
      `Util_StaticBundle.walk: assetsDir does not exist: ${assetsDir}`,
    )
  }
  let acc: array<fileEntry> = []
  walkInto(~dir=assetsDir, ~prefix="", acc)
  acc
}

/**
 * Read a JSON file at deploy time and return its exact bytes as a string, after
 * validating that it parses. A missing or malformed file throws with an
 * actionable message so a broken file fails the deploy rather than shipping a
 * file a consumer will fetch-and-ignore. The verbatim bytes are returned (not
 * re-serialised) so formatting/key order the author chose is preserved.
 */
let readJsonFileVerbatim = (~path: string, ~label: string): string => {
  if !existsSync(path) {
    JsError.throwWithMessage(`${label}: file does not exist: ${path}`)
  }
  let content = readFileSyncUtf8(path, "utf8")
  try {
    let _ = JSON.parseOrThrow(content)
    content
  } catch {
  | _ => JsError.throwWithMessage(`${label}: file is not valid JSON: ${path}`)
  }
}

/**
 * Replace `/` and `.` so a path can be used as a Pulumi resource URN segment.
 */
let sanitizeName = (relativePath: string): string =>
  relativePath
  ->String.replaceAll("/", "-")
  ->String.replaceAll(".", "-")

let extensionOf = (path: string): string => {
  let parts = path->String.split(".")
  switch parts->Array.length {
  | 0 | 1 => ""
  | n => parts->Array.getUnsafe(n - 1)->String.toLowerCase
  }
}

/**
 * MIME type for common SPA bundle extensions. Defaults to
 * application/octet-stream for unknown types and warns to console
 * so missing types surface in the deploy log.
 */
let contentTypeFor = (relativePath: string): string => {
  switch extensionOf(relativePath) {
  | "html" => "text/html; charset=utf-8"
  | "htm" => "text/html; charset=utf-8"
  | "css" => "text/css; charset=utf-8"
  | "js" | "mjs" => "application/javascript; charset=utf-8"
  | "json" => "application/json; charset=utf-8"
  | "map" => "application/json; charset=utf-8"
  | "txt" => "text/plain; charset=utf-8"
  | "xml" => "application/xml; charset=utf-8"
  | "svg" => "image/svg+xml"
  | "png" => "image/png"
  | "jpg" | "jpeg" => "image/jpeg"
  | "gif" => "image/gif"
  | "webp" => "image/webp"
  | "ico" => "image/x-icon"
  | "avif" => "image/avif"
  | "woff" => "font/woff"
  | "woff2" => "font/woff2"
  | "ttf" => "font/ttf"
  | "otf" => "font/otf"
  | "eot" => "application/vnd.ms-fontobject"
  | "wasm" => "application/wasm"
  | "pdf" => "application/pdf"
  | _ =>
    log.warn(
      ~comp="Util_StaticBundle",
      `contentTypeFor: no MIME mapping for "${relativePath}", defaulting to application/octet-stream`,
    )
    "application/octet-stream"
  }
}
