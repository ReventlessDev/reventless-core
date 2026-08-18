/**
A reference to a file the platform does **not** own.

The non-image arm of the unowned pair, and {!UploadableFile}'s counterpart: same
content fact, no store declared, nothing provisioned. See {!ImageRef} for why
the pair exists and what the grammar refuses.

@example
```rescript
@schema type event =
  | SupplierCatalogPublished({
      supplierId: @s.matches(DcbTag.string) string,
      priceList: @s.matches(Reventless.FileRef.schema) string,
    })
```
*/

/** Transparent `string`; see `Email.t`. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

let fromString = (raw: string): result<t, string> => Media_Ref.check(~what="file", raw)

/** The sury schema for a file-reference field.
    Use with `@s.matches(Reventless.FileRef.schema)`. */
let schema: S.t<t> = S.string->Semantic.refined(~id=Semantic.Id.fileRef, ~check=fromString)
