// Node.js bindings for the plugin generator.

// ── File system ──────────────────────────────────────────────────────────────

@module("node:fs")
external existsSync: string => bool = "existsSync"

@module("node:fs")
external readFileSync: (string, @as("utf8") _) => string = "readFileSync"

@module("node:fs")
external writeFileSync: (string, string, @as("utf8") _) => unit = "writeFileSync"

type dirent
@send external isDirectory: dirent => bool = "isDirectory"
@send external isFile: dirent => bool = "isFile"
@get external direntName: dirent => string = "name"

type readdirOptions = {withFileTypes: bool}

@module("node:fs")
external readdirSyncRaw: (string, readdirOptions) => array<dirent> = "readdirSync"

let readDir = (dir: string): array<dirent> =>
  try readdirSyncRaw(dir, {withFileTypes: true}) catch {
  | _ => []
  }

// ── Path ─────────────────────────────────────────────────────────────────────

@module("node:path") @variadic
external join: array<string> => string = "join"

@module("node:path") @variadic
external resolve: array<string> => string = "resolve"

@module("node:path")
external dirname: string => string = "dirname"

@module("node:path")
external basename: string => string = "basename"

// ── Process ──────────────────────────────────────────────────────────────────

@val @scope("process")
external argv: array<string> = "argv"

@val @scope("process")
external cwd: unit => string = "cwd"
