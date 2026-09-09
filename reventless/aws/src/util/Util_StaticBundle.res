let log = ReventlessCore.Logger.fromEnv()

type fileEntry = {
  relativePath: string,
  absolutePath: string,
  fileAsset: Pulumi.Asset.t,
  contentHash: string,
}

let toForwardSlashes = (p: string): string => p->String.replaceAll("\\", "/")

let isHidden = (name: string): bool => name->String.startsWith(".")

let rec walkInto = (~dir: string, ~prefix: string, acc: array<fileEntry>): unit => {
  let entries = NodeFs.readdirSync(dir, {withFileTypes: true})
  entries->Array.forEach(entry => {
    let entryName = entry->NodeFs.direntName
    if isHidden(entryName) {
      ()
    } else if entry->NodeFs.isDirectory {
      let nextPrefix = prefix == "" ? entryName : prefix ++ "/" ++ entryName
      walkInto(~dir=NodePath.join([dir, entryName]), ~prefix=nextPrefix, acc)
    } else {
      let absolutePath = NodePath.join([dir, entryName])
      let relativePath = prefix == "" ? entryName : prefix ++ "/" ++ entryName
      let bytes = NodeFs.readFileSyncBuffer(absolutePath)
      let contentHash =
        NodeCrypto.createHash("sha256")
        ->NodeCrypto.hashUpdateBuffer(bytes)
        ->NodeCrypto.hashDigest("hex")
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
  if !NodeFs.existsSync(assetsDir) {
    JsError.throwWithMessage(`Util_StaticBundle.walk: assetsDir does not exist: ${assetsDir}`)
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
  if !NodeFs.existsSync(path) {
    JsError.throwWithMessage(`${label}: file does not exist: ${path}`)
  }
  let content = NodeFs.readFileSync(path)
  try {
    let _ = JSON.parseOrThrow(content)
    content
  } catch {
  | _ => JsError.throwWithMessage(`${label}: file is not valid JSON: ${path}`)
  }
}

/**
 * Read a file at deploy time and return its exact bytes as a string, with no
 * opinion about what is in them. A missing file throws; a present one ships as
 * written.
 *
 * The counterpart to `readJsonFileVerbatim` for content this deploy cannot
 * validate. A JSON file either parses or it does not, and checking costs
 * nothing. An ES module is only known to be good once a browser has evaluated
 * it, and there is no cheap check in between: parsing it here would need a
 * JavaScript parser this deploy does not have, and a syntax check would still
 * say nothing about whether it registers anything. So the deploy checks the one
 * thing it can — that the declared path names a file — and leaves the rest to
 * the consumer, which reports what it could not use.
 */
let readFileVerbatim = (~path: string, ~label: string): string => {
  if !NodeFs.existsSync(path) {
    JsError.throwWithMessage(`${label}: file does not exist: ${path}`)
  }
  NodeFs.readFileSync(path)
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
