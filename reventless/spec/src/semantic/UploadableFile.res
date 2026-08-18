/**
A file the platform stores, referenced by the path its store minted.

The non-image arm of the uploadable family — same store derivation, same stored
representation, no media-type restriction on what may be uploaded. See
{!UploadableImage} for why the family exists and what the derived store costs.

@example
```rescript
@schema type command =
  | AddSupplierDatasheet({
      supplierId: @s.matches(DcbTag.string) string,
      datasheet: UploadableFile.t,
    })
```
*/

type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

let fromString = (raw: string): result<t, string> => StorageRef.fromString(raw)

/** The schema for a field of this type, bound to the store the ppx derived. */
let forField = (~plugin: option<string>=?, ~store: string): S.t<t> =>
  StorageRef.refinement->Semantic.mark(
    ~id=Semantic.Id.uploadableFile,
    ~payload=StoredIn({plugin, store, threshold: None}),
  )
