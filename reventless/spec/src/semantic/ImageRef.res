/**
A reference to an image the platform does **not** own.

The counterpart of {!UploadableImage}, and the difference is provisioning: this
field states the same *content* fact — the value is a picture, and renders as
one — and states nothing about where it lives. No store is declared, none is
provisioned, no upload endpoint is bound, and the value arrives from wherever
its producer got it: a supplier's CDN, another system's asset host.

Use `UploadableImage.t` for a picture the deployment stores and serves. Use this
one where the platform is a reader of somebody else's image and could not
provision a store for it if it wanted to.

## The grammar

An `http`/`https` URL, or an origin-relative path. Both are things a browser can
put in an `src`; nothing else is.

`data:` URIs are refused, and that is the rule worth stating: an event log is
append-only, so a megabyte inlined into an image field is permanent and
unfixable. That is the same hole {!StorageRef} exists to close, arriving through
a field that declares no store.

@example
```rescript
@schema type event =
  | SupplierProductListed({
      supplierId: @s.matches(DcbTag.string) string,
      thumbnail: @s.matches(Reventless.ImageRef.schema) string,
    })
```
*/

/** Transparent `string`; see `Email.t`. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

/**
Validate a raw string as a reference to an unowned image, saying why when it is
not one.

Shared by {!FileRef} through `Media_Ref.check`: the two differ in what they
depict, not in how a reference is written, so one grammar serves both.
*/
let fromString = (raw: string): result<t, string> => Media_Ref.check(~what="image", raw)

/** The sury schema for an image-reference field.
    Use with `@s.matches(Reventless.ImageRef.schema)`. */
let schema: S.t<t> = S.string->Semantic.refined(~id=Semantic.Id.imageRef, ~check=fromString)
