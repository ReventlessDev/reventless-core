/**
Module type for an aggregate's identity and schema specification.

Every aggregate defines a `Spec` module satisfying this type. The `Spec` is
used by `Platform.Aggregate.Make` and by `Behavior.T` to fix the aggregate's
command, event, and error types.

@example
```rescript
// Category.res
module Id = Id.String
let name = "Category"

@schema
type command =
  | AddCategory({categoryId: string, name: string})
  | RenameCategory({categoryId: string, name: string})
  | ArchiveCategory({categoryId: string})

@schema
type event =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryArchived({categoryId: string})

@schema
type error =
  | CategoryAlreadyExists
  | CategoryNotFound
  | CategoryAlreadyArchived
```
*/
module type Spec = {
  module Id: Id.T

  /** Logical aggregate name used as a prefix for infrastructure resource names. */
  let name: string

  /** Commands this aggregate accepts. Must carry `@schema`. */
  @schema
  type command

  /** Events this aggregate emits. Must carry `@schema`. */
  @schema
  type event

  /** Business rule violation errors. Must carry `@schema`. */
  @schema
  type error

  /** Sury schema for the command type — generated automatically by `@schema`. */
  let commandSchema: S.t<command>
}
