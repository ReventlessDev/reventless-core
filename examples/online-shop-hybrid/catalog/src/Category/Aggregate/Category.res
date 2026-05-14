// Category aggregate specification.
// A named grouping of products (e.g. "Books", "Electronics").

@@reventless.spec

@schema
type command =
  | Add({name: string})
  | Rename({name: string})
  | @authorize(AllowGroups(["Admin"])) Archive

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
