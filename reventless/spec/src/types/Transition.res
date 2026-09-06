// The lifecycle edge a command owns, declared as a value rather than as an
// attribute on the constructor.
//
// The attribute this replaces could not say it for a command a host did NOT
// declare: a variant spread splices members, while the attribute lowered to a
// dict on the parent union, so a spliced command arrived carrying no edge at
// all. Nor could it be checked — the PPX extracts leaf identifiers as strings,
// and the states belong to another component's enum, so a misspelling survived
// to the plugin structure.
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
  /** Legal in every state, and moves the row nowhere. The honest answer for a
      report a slice publishes, which must not be refused because the row moved
      on while the report was in flight. A claim, not an omission — see
      `Undeclared`, which is the omission. */
  | Unrestricted
  /** The spec wrote no switch, and the ppx injected this. Never write it: say
      `Unrestricted` if you mean the command is legal everywhere.

      It reads exactly like `Unrestricted` — no from-set, no target — everywhere
      but one place, and that place is why it exists. The harvested lifecycle
      model may answer for silence; it may not narrow a claim. A corpus only
      covers the states somebody wrote a scenario for, so letting it answer for
      `Unrestricted` would shrink "legal in every state" down to an accident of
      coverage, and the command would quietly stop being offered on the rows
      nobody tested. With the two spelled apart, that shrinkage cannot happen and
      a scenario that genuinely refutes the claim is a contradiction instead. */
  | Undeclared
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
  | Undeclared
  | Unrestricted
  | Creates(_) => None
  | Guards(states)
  | Moves(states, _) => Some(states)
  }

/** The state the command's handler writes, or `None` for one that moves nothing. */
let targetState = (transition: t<'state>): option<'state> =>
  switch transition {
  | Undeclared
  | Unrestricted
  | Guards(_) => None
  | Creates(state)
  | Moves(_, state) => Some(state)
  }

/** Whether the command is claimed legal in every state, as opposed to nothing
    being claimed at all. The two erase to the same pair of `None`s above, so this
    is the only thing that can tell a reader of the erased form which it holds. */
let isUnrestricted = (transition: t<'state>): bool =>
  switch transition {
  | Unrestricted => true
  | Undeclared
  | Creates(_)
  | Guards(_)
  | Moves(_, _) => false
  }
