// Shared D2 source-emission primitives — single-sources the double-quoted-string
// escaping every D2 generator (DomainGraphD2 here; the extension's ContextMapD2 /
// ScenarioD2 downstream) previously carried an identical copy of, so the escaping
// rules live in exactly one place.

// D2 double-quoted string escape: ids/labels can carry `.`/`:`/`_`/spaces; quote and
// escape any embedded backslash/quote so the value stays a valid d2 string. Backslash
// is doubled FIRST so an already-escaped quote (e.g. `\"` from `JSON.stringify`) keeps
// its backslash rather than having the quote-escape introduce a stray one.
let q = (s: string): string => {
  let escaped =
    s
    ->String.replaceRegExp(%re("/\\/g"), "\\\\")
    ->String.replaceRegExp(%re("/\"/g"), "\\\"")
  `"${escaped}"`
}

// Like `q`, but for multi-line node labels: a real newline becomes d2's `\n` escape
// (d2 rejects literal newlines inside a quoted string). Same backslash-first ordering
// as `q` — double any pre-existing backslash before introducing the `\n`/`\"` escapes,
// whose own backslashes must stay single.
let qLabel = (s: string): string => {
  let escaped =
    s
    ->String.replaceRegExp(%re("/\\/g"), "\\\\")
    ->String.replaceRegExp(%re("/\"/g"), "\\\"")
    ->String.replaceRegExp(%re("/\n/g"), "\\n")
  `"${escaped}"`
}
