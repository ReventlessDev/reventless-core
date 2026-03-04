// Category aggregate specification.
// A named grouping of products (e.g. "Books", "Electronics").

open Reventless
module Id = Id.String

let name = "Category"

@schema
type command =
  | Add({name: string})
  | Rename({name: string})
  | Archive

@schema
type event =
  | Added({name: string})
  | Renamed({name: string})
  | Archived

@schema
type error =
  | CategoryAlreadyExists
  | CategoryNotFound
  | CategoryAlreadyArchived
