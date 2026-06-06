// Selects which storage backend the in-memory Platform uses.
//
// Memory   — pure in-memory dicts/refs, current default behaviour, wiped on restart.
// Sqlite   — opt-in on-disk SQLite file via SqliteDriver. Survives process restart.
//             resetOnStart=true wipes the file when the Platform is constructed.

type t =
  | Memory
  | Sqlite({path: string, resetOnStart: bool})

let memory = Memory
let sqlite = (~path, ~resetOnStart=false) => Sqlite({path, resetOnStart})

@val external processEnv: dict<string> = "process.env"

// Deletes a file if it exists. No-op if the path is missing.
@module("node:fs") external _unlinkSync: string => unit = "unlinkSync"

let removeFileIfExists = (path: string) =>
  try _unlinkSync(path) catch {
  | _ => ()
  }

// Parses REVENTLESS_LOCAL_BACKEND. Recognised forms:
//   sqlite:./local.db        — Sqlite backend, no reset on start
//   sqlite:./local.db?reset  — Sqlite backend, wipes file at Platform.Make time
//   memory                   — explicit Memory selector
// Anything else (including unset) yields Memory.
let fromEnv = () =>
  switch processEnv->Dict.get("REVENTLESS_LOCAL_BACKEND") {
  | None => Memory
  | Some(raw) =>
    let trimmed = raw->String.trim
    if trimmed == "" || trimmed == "memory" {
      Memory
    } else if trimmed->String.startsWith("sqlite:") {
      let rest = trimmed->String.slice(~start=String.length("sqlite:"), ~end=String.length(trimmed))
      let (path, resetOnStart) = switch rest->String.split("?") {
      | [p, q] => (p, q->String.split("&")->Array.includes("reset"))
      | _ => (rest, false)
      }
      Sqlite({path, resetOnStart})
    } else {
      Memory
    }
  }
