// Worked example for StateChangeSlice_GWT.
// Uses the canonical "AddCategory" DCB slice shape — payload-less consumed
// events, decide that appends `CategoryAdded` unless the category already
// exists. Command carries a `@s.matches(DcbTag.string)` annotated ID so the
// DCB optimistic-concurrency query resolves to a single-entity read.

module AddCategorySlice = {
  let name = "AddCategory"

  type state = {exists: bool, archived: bool}
  let initialState = {exists: false, archived: false}

  @schema
  type consumedEvent =
    | CategoryAdded
    | CategoryArchived

  let evolve = (state, event) =>
    switch event {
    | CategoryAdded => {exists: true, archived: false}
    | CategoryArchived => {...state, archived: true}
    }

  @schema
  type command =
    AddCategory({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

  @schema
  type error = CategoryAlreadyExists

  @schema
  type event =
    CategoryAdded({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

  let decide = (state, command) =>
    switch command {
    | AddCategory({categoryId, name}) =>
      state.exists ? Error(CategoryAlreadyExists) : Ok([CategoryAdded({categoryId, name})])
    }
}

include StateChangeSlice_GWT.Make(AddCategorySlice)

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

  type state = unit
  let initialState = ()

  @schema
  type consumedEvent = Noop

  let evolve = (state, _event) => state

  @schema
  type command = Do({id: string})

  @schema
  type error = Rejected

  @schema
  type event = Done({id: string})

  let decide = (_state, cmd) =>
    switch cmd {
    | Do({id}) => Ok([Done({id: id})])
    }
}

module MissingTagGwt = StateChangeSlice_GWT.Make(MissingTagSlice)

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
