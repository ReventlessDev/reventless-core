// Component-level visibility hint. Controls whether a ReadModel or
// StateViewSlice appears in the auto-generated AutoUI manifest.
//
// `Internal` is a UX hint, NOT a security boundary. Internal components
// remain queryable via GraphQL, retain their resolvers, and stay in the
// platform's event graph — they are only hidden from AutoUI's menu /
// panel enumeration. Use `Authorization.permission` for access control.
//
// The variant is shipped with two cases initially. Future cases (e.g.
// `UnlistedInAutoUI`, `InternalToPlugin`, `Hidden`) can be added without
// breaking existing `@@reventless.visibility(Internal)` declarations.

@schema
type t =
  | Public
  | Internal

let default = Public

let toString = (v: t) =>
  switch v {
  | Public => "Public"
  | Internal => "Internal"
  }
