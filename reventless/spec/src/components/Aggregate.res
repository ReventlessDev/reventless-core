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

  /** File URL of this module (`import.meta.url`). Used by AWS builders to derive
      the npm specifier for runtime dynamic imports. */
  let moduleUrl: string

  /** Authorization rule evaluated at the GraphQL resolver entry before any
      command is dispatched. Auto-injected by `@@reventless.spec` and on
      structurally-detected inline spec modules — defaults to
      `AllowAuthenticated`; override at the file/module level with
      `@@reventless.authorize(<rule>)`. */
  let commandAuthorization: command => Authorization.permission

  /** The lifecycle enum this component's commands move a row through — the
      linked view's own, e.g. `type lifecycleState = Customers.accountStatus`.
      Auto-injected as `unit` alongside the default below; a host that declares
      `commandTransition` declares this too, and the pair is what makes every
      edge name one lifecycle. */
  type lifecycleState

  /** The lifecycle edge each command owns, read while the plugin structure is
      assembled. Auto-injected as `_ => Unrestricted` by `@@reventless.spec`,
      which leaves `@transition` in charge; a host that writes the switch by
      hand takes charge instead, and gets an exhaustive one over typed states.
      See `Transition`. */
  let commandTransition: command => Transition.t<lifecycleState>

  /** The domain traits grafted into this component, as values the trait packages
      export — `[TraitAttachments.Attachments.declaration]`. Auto-injected as `[]`
      by `@@reventless.spec`, so a component that is nobody's graft says so without
      a line. A graft names its trait here and the structure records it, which is
      the only way a deployed plugin can answer "where did this come from". See
      `Trait`. */
  let traits: array<Trait.t>
}
