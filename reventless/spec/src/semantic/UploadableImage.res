/**
An image the platform stores, referenced by the path its store minted.

## What this says that `@storageRef` does not

`@storageRef("productImages") imageUrl?: string` states two facts and declares
only one. It says *where* the value lives — typed, validated, provisioned — and
leaves *what the value is* to be guessed from the field being called `imageUrl`.
This type states both, so the same declaration picks the renderer and the upload
endpoint.

## No store argument

The store is the field's name, pluralised, derived by the ppx —
`productImage: UploadableImage.t` requires the `productImages` store. So a field
declares its store by being named, and renaming the field renames the store:
treat a rename of a live field as a data migration, or keep the old store with an
explicit `@storageRef("…")`, which still wins.

The stored value is unchanged from `StorageRef`: an origin-relative
`/{prefix}/{key}` string, validated by the same refinement. Retyping an existing
`@storageRef` field to this one alters no stored bytes — only the field's *name*
does, and only because the store is derived from it.

@example
```rescript
@schema type command =
  | ChangeProductImage({
      productId: @s.matches(DcbTag.string) string,
      productImage: UploadableImage.t,
    })
```
*/

/** Transparent `string`, for `StorageRef.t`'s reason: the marker refines an
    existing field rather than replacing it, so nothing stored changes. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

/** The grammar, which is `StorageRef`'s — one definition, no second copy. */
let fromString = (raw: string): result<t, string> => StorageRef.fromString(raw)

/**
The schema for a field of this type, bound to the store the ppx derived.

Prefer typing the field `UploadableImage.t` and letting `UploadableInference`
call this. Written by hand it needs the derived store name, which defeats the
point of the type.
*/
let forField = (~plugin: option<string>=?, ~store: string): S.t<t> =>
  StorageRef.refinement->Semantic.mark(
    ~id=Semantic.Id.uploadableImage,
    ~payload=StoredIn({plugin, store, threshold: None}),
  )
