/**
Marks a `string` field as a web address.

## The grammar: parseable, **and** `http`/`https`

Sury's `S.url` is the parse — it is `new URL()`, so it settles host, port and
escaping without this module having an opinion. But `new URL()` accepts every
scheme, `javascript:alert(1)` included, and that is not an academic gap here: a
field carrying this semantic renders as an anchor whose `href` is the stored
value. An append-only log plus a scheme nobody checked is a stored XSS that
cannot be deleted afterwards — the same shape of hole `StorageRef` exists to
close, arriving through a different field.

So the grammar is sury's parse plus a two-scheme allowlist. `mailto:` and `tel:`
are deliberately outside it: those are `Email` and `Phone`, which validate what
they actually hold and render correctly on their own.

@example
```rescript
@schema type command =
  | SetSupplierSite({
      supplierId: @s.matches(DcbTag.string) string,
      website: @s.matches(Reventless.Url.schema) string,
    })
```
*/

/** The address's representation. Transparent `string`; see `Email.t`. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

// Sury's parse, held once — `fromString` runs it and adds the scheme check, and
// `schema` derives from `fromString`. One grammar, in one place.
let grammar: S.t<string> = S.string->S.url

// Schemes are case-insensitive per RFC 3986, and `HTTPS://x` parses fine, so the
// allowlist has to fold case or it rejects a valid address on a technicality.
let hasWebScheme = (raw: string): bool => {
  let lower = String.toLowerCase(raw)
  String.startsWith(lower, "http://") || String.startsWith(lower, "https://")
}

/** Validate a raw string as an `http`/`https` URL, saying why when it is not one. */
let fromString = (raw: string): result<t, string> =>
  switch raw->S.parseOrThrow(grammar) {
  | value =>
    if hasWebScheme(value) {
      Ok(value)
    } else {
      Error(
        `a URL field takes an http:// or https:// address, got ${Semantic.showString(raw)}. ` ++
        `Use Email or Phone for mailto:/tel:, and a storage ref for an uploaded object.`,
      )
    }
  | exception _ =>
    Error(
      `expected an absolute URL, got ${Semantic.showString(
          raw,
        )}. A relative path is not a URL — include the scheme and host.`,
    )
  }

/** The sury schema for a URL field. Use with `@s.matches(Reventless.Url.schema)`. */
let schema: S.t<t> = S.string->Semantic.refined(~id=Semantic.Id.url, ~check=fromString)
