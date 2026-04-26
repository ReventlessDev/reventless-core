// Worked example for Behavior_GWT (slice flavor).
// Uses the canonical "AddCategory" DCB slice shape — payload-less consumed
// events, decide that appends `CategoryAdded` unless the category already
// exists. Command carries a `@s.matches(DcbTag.string)` annotated ID so the
// DCB optimistic-concurrency query resolves to a single-entity read.
//
// Plan 02 Phase 6: split-form Spec/Behavior; PPX inference resolves the
// folder kind from the test path's "StateChangeSlice" substring → Behavior
// DSL → emits [include Behavior_GWT.Make(Spec, Behavior)].

@@reventless.gwt

module AddCategorySlice = {
  let name = "AddCategory"

  @schema
  type consumedEvent =
    | CategoryAdded
    | CategoryArchived

  @schema
  type command =
    AddCategory({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

  @schema
  type error = CategoryAlreadyExists

  @schema
  type event =
    CategoryAdded({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})
}

module AddCategorySliceBehavior = {
  module Spec = AddCategorySlice
  open AddCategorySlice

  type state = {exists: bool, archived: bool}
  let initialState: state = {exists: false, archived: false}

  let evolve = (state: state, event: consumedEvent): state =>
    switch event {
    | CategoryAdded => {exists: true, archived: false}
    | CategoryArchived => {...state, archived: true}
    }

  let decide = (state: state, command: command): result<array<event>, error> =>
    switch command {
    | AddCategory({categoryId, name}) =>
      state.exists ? Error(CategoryAlreadyExists) : Ok([CategoryAdded({categoryId, name})])
    }
}

describe("AddCategory StateChangeSlice", () => {
  test("on empty event log produces CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
  )

  test("on existing category returns CategoryAlreadyExists", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(AddCategory({categoryId: "c1", name: "X"}))
    ->thenError(CategoryAlreadyExists)
  )

  test("append condition is single-entity query over consumed event types", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenAppendsConditionedOn([
      {
        eventTypes: ["CategoryAdded", "CategoryArchived"],
        tags: [{key: "categoryId", value: "c1"}],
      },
    ])
  )

  test("exact condition matches no prior position (new entity)", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: "c2", name: "Books"}))
    ->thenAppendsConditionedOnExactly({
      query: [
        {
          eventTypes: ["CategoryAdded", "CategoryArchived"],
          tags: [{key: "categoryId", value: "c2"}],
        },
      ],
    })
  )
})

// A second slice whose command has no `@s.matches(DcbTag.string)` annotation —
// verifies the implicit Stage 4 check fires with `AppendConditionMismatch`
// before any subsequent `then*` runs its own assertion.
module MissingTagSlice = {
  let name = "MissingTagSlice"

  @schema
  type consumedEvent = Noop

  @schema
  type command = Do({id: string})

  @schema
  type error = Rejected

  @schema
  type event = Done({id: string})
}

module MissingTagBehavior = {
  // Qualify references through [Spec] to avoid shadowing the file-scope
  // [consumedEvent] / [command] / [event] / [error] brought in by the PPX-
  // injected [open AddCategorySlice].
  module Spec = MissingTagSlice

  type state = unit
  let initialState: state = ()

  let evolve = (state: state, _event: Spec.consumedEvent): state => state

  let decide = (
    _state: state,
    cmd: Spec.command,
  ): result<array<Spec.event>, Spec.error> =>
    switch cmd {
    | Do({id}) => Ok([Spec.Done({id: id})])
    }
}

module MissingTagGwt = Behavior_GWT.Make(MissingTagSlice, MissingTagBehavior)

MissingTagGwt.describe("MissingTag slice implicit check", () => {
  MissingTagGwt.test("thenEvent surfaces AppendConditionMismatch when command lacks DCB tag", () => {
    let outcome =
      MissingTagGwt.givenEvents([])
      ->MissingTagGwt.whenCmd(Do({id: "x1"}))
      ->MissingTagGwt.thenEvent(Done({id: "x1"}))
    switch outcome {
    | Error(AppendConditionMismatch(_)) => Outcome.pass
    | Error(other) =>
      Outcome.fail(
        Throw({error: "expected AppendConditionMismatch, got: " ++ Outcome.kindName(other), stack: ""}),
      )
    | Ok() =>
      Outcome.fail(
        Throw({error: "expected AppendConditionMismatch, got pass", stack: ""}),
      )
    }
  })

  MissingTagGwt.test(
    "thenAppendsConditionedOnExactly bypasses implicit check (still passes with derived)",
    () =>
      MissingTagGwt.givenEvents([])
      ->MissingTagGwt.whenCmd(Do({id: "x1"}))
      ->MissingTagGwt.thenAppendsConditionedOnExactly({
        query: [{eventTypes: ["Noop"], tags: []}],
      }),
  )
})
