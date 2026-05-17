open ReventlessCore

// Minimal inline spec for AutomationSlice — mirrors the pattern used by
// the other GWT DSLs so sury-ppx processes the @schema attributes in this
// compilation unit.
module type SliceSpec = {
  let name: string

  @schema
  type consumedEvent

  @schema
  type todoItem

  @schema
  type command

  let collect: consumedEvent => array<(string, todoItem)>
  let resolve: consumedEvent => option<string>
  let process: (string, todoItem) => option<(string, command)>
}

module type T = {
  module Spec: SliceSpec

  let describe: (string, unit => unit) => unit
  let test: (string, unit => Outcome.outcome) => unit

  // Scenario state — after a sweep, the pipeline carries pending todos plus
  // the commands emitted by process(). `andThenEvents` drains resolved todos.
  type scenario = {
    todos: array<(string, Spec.todoItem)>,
    commands: array<(string, Spec.command)>,
  }

  // Unit combinators — collect
  let givenEvent: Spec.consumedEvent => Spec.consumedEvent
  let whenCollect: Spec.consumedEvent => array<(string, Spec.todoItem)>
  let thenTodos: (
    array<(string, Spec.todoItem)>,
    array<(string, Spec.todoItem)>,
  ) => Outcome.outcome

  // Unit combinators — resolve
  let whenResolve: Spec.consumedEvent => option<string>
  let thenResolved: (option<string>, option<string>) => Outcome.outcome

  // Unit combinators — process
  let givenTodo: (string, Spec.todoItem) => (string, Spec.todoItem)
  let whenProcess: ((string, Spec.todoItem)) => option<(string, Spec.command)>
  let thenCommand: (option<(string, Spec.command)>, string, Spec.command) => Outcome.outcome
  let thenNoCommand: option<(string, Spec.command)> => Outcome.outcome

  // Scenario combinators — full sweep
  let givenEvents: array<Spec.consumedEvent> => array<Spec.consumedEvent>
  let whenSweep: array<Spec.consumedEvent> => scenario
  let thenCommands: (scenario, array<(string, Spec.command)>) => Outcome.outcome
  let andThenEvents: (scenario, array<Spec.consumedEvent>) => scenario
  let thenScenarioTodos: (scenario, array<(string, Spec.todoItem)>) => Outcome.outcome
}

module Make = (Spec: SliceSpec): (T with module Spec = Spec) => {
  module Spec = Spec


  let describe = JestBind.describe
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  type scenario = {
    todos: array<(string, Spec.todoItem)>,
    commands: array<(string, Spec.command)>,
  }

  let encTodo = (t: Spec.todoItem) => t->Message.encode(Spec.todoItemSchema)
  let encTodos = (arr: array<(string, Spec.todoItem)>) =>
    arr->Array.map(((id, t)) => (id, encTodo(t)))
  let encCommand = (c: Spec.command) => c->Message.encode(Spec.commandSchema)

  // Unit: collect
  let givenEvent = e => e
  let whenCollect = e => e->Spec.collect
  let thenTodos = (actual, expected) =>
    if actual == expected {
      Outcome.pass
    } else {
      Outcome.fail(
        TodoMismatch({
          expected: encTodos(expected),
          actual: encTodos(actual),
        }),
      )
    }

  // Unit: resolve
  let whenResolve = e => e->Spec.resolve
  let thenResolved = (actual, expected) =>
    if actual == expected {
      Outcome.pass
    } else {
      let asPair = opt =>
        switch opt {
        | Some(id) => [(id, JSON.Encode.null)]
        | None => []
        }
      Outcome.fail(
        TodoMismatch({
          expected: asPair(expected),
          actual: asPair(actual),
        }),
      )
    }

  // Unit: process
  let givenTodo = (id, todo) => (id, todo)
  let whenProcess = ((id, todo)) => Spec.process(id, todo)
  let thenCommand = (actual, expectedId, expectedCmd) =>
    switch actual {
    | Some((id, cmd)) if id == expectedId && cmd == expectedCmd => Outcome.pass
    | Some((id, cmd)) =>
      let obj = (rid, rcmd) => {
        let d = Dict.make()
        d->Dict.set("id", JSON.Encode.string(rid))
        d->Dict.set("command", encCommand(rcmd))
        JSON.Encode.object(d)
      }
      Outcome.fail(
        EventsMismatch({
          expected: [obj(expectedId, expectedCmd)],
          actual: [obj(id, cmd)],
        }),
      )
    | None =>
      let obj = (rid, rcmd) => {
        let d = Dict.make()
        d->Dict.set("id", JSON.Encode.string(rid))
        d->Dict.set("command", encCommand(rcmd))
        JSON.Encode.object(d)
      }
      Outcome.fail(
        EventsMismatch({
          expected: [obj(expectedId, expectedCmd)],
          actual: [],
        }),
      )
    }
  let thenNoCommand = actual =>
    switch actual {
    | None => Outcome.pass
    | Some((id, cmd)) =>
      let obj = {
        let d = Dict.make()
        d->Dict.set("id", JSON.Encode.string(id))
        d->Dict.set("command", encCommand(cmd))
        JSON.Encode.object(d)
      }
      Outcome.fail(NoEventExpected({actual: [obj]}))
    }

  // Scenario: full sweep
  let givenEvents = es => es
  let whenSweep = events => {
    // Build the todo list by running collect, then drain any items that are
    // completed by resolve in the same input stream.
    let collected =
      events->Array.map(e => e->Spec.collect)->Array.flat
    let resolvedIds =
      events->Array.filterMap(e => e->Spec.resolve)
    let pending =
      collected->Array.filter(((id, _)) => !Array.includes(resolvedIds, id))

    // Process each pending todo to produce commands.
    let commands =
      pending->Array.filterMap(((id, todo)) => Spec.process(id, todo))

    {todos: pending, commands}
  }

  let thenCommands = (scenario, expected) =>
    if scenario.commands == expected {
      Outcome.pass
    } else {
      let toJsonPairs = arr =>
        arr->Array.map(((id, cmd)) => {
          let d = Dict.make()
          d->Dict.set("id", JSON.Encode.string(id))
          d->Dict.set("command", encCommand(cmd))
          JSON.Encode.object(d)
        })
      Outcome.fail(
        EventsMismatch({
          expected: toJsonPairs(expected),
          actual: toJsonPairs(scenario.commands),
        }),
      )
    }

  let andThenEvents = (scenario, events) => {
    let resolvedIds =
      events->Array.filterMap(e => e->Spec.resolve)
    let remaining =
      scenario.todos->Array.filter(((id, _)) => !Array.includes(resolvedIds, id))
    {...scenario, todos: remaining}
  }

  let thenScenarioTodos = (scenario, expected) => thenTodos(scenario.todos, expected)
}
