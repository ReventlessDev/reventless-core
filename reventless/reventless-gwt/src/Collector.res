// Module-level collector used by the CLI runner.
//
// When the CLI loads a test file via dynamic import, each `describe`/`test`
// call routes through `Bind` or `JestBind` and pushes an entry into this
// collector. After the import resolves (all registrations complete), the CLI
// drains the entries, executes each body asynchronously, and feeds the results
// into a formatter.
//
// Activation is toggled by the CLI — when inactive, `JestBind` falls back to
// Jest globals, so existing Jest test runs are unaffected.

type status = Skipped | Runnable | Only

type location = {
  file: string,
  line: int,
  column: int,
}

type entry = {
  id: string,
  name: string,
  describePath: array<string>,
  slice: option<string>,
  body: unit => promise<Outcome.outcome>,
  status: status,
  location: option<location>,
}

let active = ref(false)
let describeStack: ref<array<string>> = ref([])
let entries: ref<array<entry>> = ref([])
let hasOnly = ref(false)
let skipNext = ref(false)
let onlyNext = ref(false)
let skipDepth = ref(0)
let currentFile: ref<option<string>> = ref(None)

let activate = () => {
  active := true
  describeStack := []
  entries := []
  hasOnly := false
  skipNext := false
  onlyNext := false
  currentFile := None
}

let deactivate = () => active := false
let isActive = () => active.contents

let setCurrentFile = path => currentFile := Some(path)
let getCurrentFile = () => currentFile.contents

let markSkipNext = () => skipNext := true
let markOnlyNext = () => {
  onlyNext := true
  hasOnly := true
}

let pushDescribe = (label: string, body: unit => unit) => {
  describeStack := Array.concat(describeStack.contents, [label])
  body()
  let ds = describeStack.contents
  describeStack := ds->Array.slice(~start=0, ~end=ds->Array.length - 1)
}

let buildId = (describePath, name) => {
  let prefix = describePath->Array.join("::")
  prefix == "" ? name : prefix ++ "::" ++ name
}

let push = (
  ~slice=?,
  ~location=?,
  name: string,
  body: unit => promise<Outcome.outcome>,
) => {
  let status = if skipDepth.contents > 0 {
    Skipped
  } else if skipNext.contents {
    skipNext := false
    Skipped
  } else if onlyNext.contents {
    onlyNext := false
    Only
  } else {
    Runnable
  }
  let describePath = describeStack.contents
  let id = buildId(describePath, name)
  let entry = {
    id,
    name,
    describePath,
    slice,
    body,
    status,
    location,
  }
  entries := Array.concat(entries.contents, [entry])
}

let drain = () => {
  let result = entries.contents
  entries := []
  describeStack := []
  result
}

// Parse a single V8 stack frame line like:
//   "    at body (/abs/path/File.res.mjs:42:13)"
//   "    at /abs/path/File.res.mjs:42:13"
// Returns (file, line, column) if the frame belongs to a non-internal user file.
let parseFrame = (frame: string): option<location> => {
  let trimmed = frame->String.trim
  let body = if String.startsWith(trimmed, "at ") {
    String.slice(trimmed, ~start=3, ~end=String.length(trimmed))
  } else {
    trimmed
  }
  let withLoc = switch String.lastIndexOf(body, "(") {
  | -1 => body
  | i =>
    let rest = String.slice(body, ~start=i + 1, ~end=String.length(body))
    switch String.lastIndexOf(rest, ")") {
    | -1 => rest
    | j => String.slice(rest, ~start=0, ~end=j)
    }
  }
  let parts = withLoc->String.split(":")
  let n = parts->Array.length
  if n < 3 {
    None
  } else {
    let col = parts->Array.getUnsafe(n - 1)->Int.fromString
    let line = parts->Array.getUnsafe(n - 2)->Int.fromString
    let file =
      parts->Array.slice(~start=0, ~end=n - 2)->Array.join(":")
    let file = if String.startsWith(file, "file://") {
      String.slice(file, ~start=7, ~end=String.length(file))
    } else {
      file
    }
    // Strip the Loader's `?t=N` cache-busting query so locations point at the
    // real file path.
    let file = switch String.indexOf(file, "?") {
    | -1 => file
    | q => String.slice(file, ~start=0, ~end=q)
    }
    switch (line, col) {
    | (Some(l), Some(c)) => Some({file, line: l, column: c})
    | _ => None
    }
  }
}

// Walk a captured stack and return the first frame that lives in a test
// file outside the reventless-gwt package itself.
let captureLocation = (skip: int): option<location> => {
  let stack: option<string> = %raw(`(new Error()).stack`)
  switch stack {
  | None => None
  | Some(s) =>
    let lines = s->String.split("\n")
    let total = lines->Array.length
    // Skip the "Error" header, plus `skip` internal frames.
    let rec find = i =>
      if i >= total {
        None
      } else {
        let frame = lines->Array.getUnsafe(i)
        switch parseFrame(frame) {
        | Some(loc)
          if !(loc.file->String.includes("reventless-gwt/src/")) &&
            !(loc.file->String.includes("node_modules/")) =>
          Some(loc)
        | _ => find(i + 1)
        }
      }
    find(skip + 1)
  }
}
