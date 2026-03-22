/**
Module type for a DCB (Distributed Command Behavior) event log specification.

A DCB event log is a shared, append-only log used by multiple `StateChangeSlice`
and `StateViewSlice` components. All slices that belong to the same log share
the same `event` union type.

@example
```rescript
// CatalogEventLog.res
@schema
type event =
  | ProductAdded({productId: @s.matches(DcbTag.string) string, name: string, description: string, price: float})
  | ProductNameUpdated({productId: @s.matches(DcbTag.string) string, name: string})
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryRenamed({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})
```
*/
module type Spec = {
  let moduleUrl: string

  /** The union of all event types stored in this DCB event log. Must carry `@schema`. */
  @schema
  type event
}
