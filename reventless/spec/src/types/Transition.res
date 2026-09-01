// The lifecycle edge a command owns, declared as a value rather than as an
// attribute on the constructor.
//
// `@transition([Orders.Placed] => Orders.Shipped)` says the same thing and is
// still the shorter spelling for a command a host declares itself. It cannot say
// it for a command a host did NOT declare: a variant spread splices members,
// while the annotation lowers to a dict on the parent union, so a spliced
// command arrives carrying no edge at all. Nor can the annotation be checked —
// the PPX extracts leaf identifiers as strings, and the states belong to another
// component's enum, so a misspelling survives to the plugin structure.
//
// A `command => t<'state>` switch answers both. It is exhaustive, so a spliced
// constructor is a compile error until the host says what it does; and `'state`
// is the view's own lifecycle enum, so `Customers.Active` is a constructor the
// compiler resolves rather than a string nobody reads.
//
// `'state` is one type across the whole switch, which is a third thing the
// annotation cannot do: every arm of one component's edges must name the same
// lifecycle, and a from-set drawn from one enum with a target from another does
// not compile.
//
// The type stays parameterised all the way down rather than storing names,
// because erasing a constructor to its own name means asserting its runtime
// representation — and this is the module that exists so nothing has to be
// asserted. The erasure happens once, at the framework's type-erasure boundary
// (`Plugin_Structure`), which already reads every spec member that way.
//
// The reference costs nothing at run time. A lifecycle enum's arms are
// payload-less, so `[Customers.Active]` compiles to `["Active"]` and the
// generated module imports nothing from the view — which is also why it cannot
// cycle: a view spec holds no reference back to the aggregate it projects.
//
// Read the same way `commandAuthorization` is: `Plugin_Structure.toCommandDef`
// evaluates it against a synthetic value per constructor.
//
// No `@schema`: nothing serialises a transition. It is read once, while the
// plugin structure is assembled, and what leaves is the pair of names the
// structure already carried.
type t<'state> =
  /** No edge declared: legal in every state, moves the row nowhere. The honest
      answer for a report a slice publishes, which must not be refused because
      the row moved on while the report was in flight. */
  | Unrestricted
  /** Brings the row into existence, so there is no state it could come from.
      Distinct from `Unrestricted`, which draws no edge at all. */
  | Creates('state)
  /** Legal in these states, and moves the row nowhere. A positive claim rather
      than an omission. */
  | Guards(array<'state>)
  /** Legal in these states, and lands the row in that one. */
  | Moves(array<'state>, 'state)

/** The from-set, or `None` for a command that names no states to come from —
    which `Creates` and `Unrestricted` both do, for different reasons the target
    tells apart. */
let allowedStates = (transition: t<'state>): option<array<'state>> =>
  switch transition {
  | Unrestricted
  | Creates(_) => None
  | Guards(states)
  | Moves(states, _) => Some(states)
  }

/** The state the command's handler writes, or `None` for one that moves nothing. */
let targetState = (transition: t<'state>): option<'state> =>
  switch transition {
  | Unrestricted
  | Guards(_) => None
  | Creates(state)
  | Moves(_, state) => Some(state)
  }
