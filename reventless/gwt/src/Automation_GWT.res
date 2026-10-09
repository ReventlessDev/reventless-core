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
  let thenTodos: (array<(string, Spec.todoItem)>, array<(string, Spec.todoItem)>) => Outcome.outcome

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

/** Deprecated: takes an adapter module that flattens one mapping. Use
    `FromSlice`, which takes the slice as written; this goes one release after
    the examples have moved. */
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
    let collected = events->Array.map(e => e->Spec.collect)->Array.flat
    let resolvedIds = events->Array.filterMap(e => e->Spec.resolve)
    let pending = collected->Array.filter(((id, _)) => !Array.includes(resolvedIds, id))

    // Process each pending todo to produce commands.
    let commands = pending->Array.filterMap(((id, todo)) => Spec.process(id, todo))

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
    let resolvedIds = events->Array.filterMap(e => e->Spec.resolve)
    let remaining = scenario.todos->Array.filter(((id, _)) => !Array.includes(resolvedIds, id))
    {...scenario, todos: remaining}
  }

  let thenScenarioTodos = (scenario, expected) => thenTodos(scenario.todos, expected)
}

// The slice as written: its `Spec` and its `_Automation` body, with every
// mapping, `process` and `onExhausted`. Per-source verbs come from
// `Mapping(M)`, because a mapping's event type is hidden inside `mappings`.
module FromSlice = (
  Spec: Reventless.AutomationSlice.Spec,
  Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
) => {
  module Route = AutomationSlice_Route.Make(Spec, Automation)

  let describe = JestBind.describe
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  let testContext: Reventless.AutomationSlice.context = {
    environment: "test",
    platformName: "test",
    pluginName: "test",
    sliceName: Spec.name,
  }

  /** A source event as the runtime receives it: encoded, and addressed by its
      source's name. Built with `Mapping(M).event`. */
  type sourced = {sourceName: string, sourceId: string, payload: JSON.t}

  type scenario = {
    todos: array<(string, Spec.todoItem)>,
    commands: array<(string, Spec.command)>,
  }

  let encTodos = (arr: array<(string, Spec.todoItem)>) =>
    arr->Array.map(((id, t)) => (id, t->Message.encode(Spec.todoItemSchema)))
  let encPair = ((id, cmd): (string, Spec.command)) => {
    let d = Dict.make()
    d->Dict.set("id", JSON.Encode.string(id))
    d->Dict.set("command", cmd->Message.encode(Spec.commandSchema))
    JSON.Encode.object(d)
  }

  let thenTodos = (actual, expected) =>
    actual == expected
      ? Outcome.pass
      : Outcome.fail(TodoMismatch({expected: encTodos(expected), actual: encTodos(actual)}))

  let thenResolved = (actual: option<string>, expected: option<string>) => {
    let asPair = opt => opt->Option.mapOr([], id => [(id, JSON.Encode.null)])
    actual == expected
      ? Outcome.pass
      : Outcome.fail(TodoMismatch({expected: asPair(expected), actual: asPair(actual)}))
  }

  module Mapping = (M: Automation.Mapping) => {
    let event = (e: M.sourceEvent, ~sourceId="") => {
      sourceName: M.sourceName,
      sourceId,
      payload: e->Message.encode(M.sourceEventSchema),
    }
    let givenEvent = (e: M.sourceEvent) => e
    let whenCollect = (e, ~sourceId="", ~context=testContext) => M.collect(e, ~sourceId, context)
    let whenResolve = M.resolve
  }

  // Unit: process and abandonment
  let givenTodo = (id: string, item: Spec.todoItem) => (id, item)
  let whenProcess = ((id, item)) => Automation.process(id, item)
  let whenExhausted = ((id, item)) => Automation.onExhausted(id, item)
  let thenCommand = (actual, expectedId, expectedCmd) =>
    switch actual {
    | Some((id, cmd)) if id == expectedId && cmd == expectedCmd => Outcome.pass
    | actual =>
      Outcome.fail(
        EventsMismatch({
          expected: [encPair((expectedId, expectedCmd))],
          actual: actual->Option.mapOr([], p => [encPair(p)]),
        }),
      )
    }
  let thenNoCommand = actual =>
    switch actual {
    | None => Outcome.pass
    | Some(p) => Outcome.fail(NoEventExpected({actual: [encPair(p)]}))
    }

  // Scenario: a sweep routes each event in turn, as phase 1 does, so to-dos keep
  // the order the events produced them.
  let givenEvents = (es: array<sourced>) => es
  let routeAll = (events: array<sourced>, context) =>
    events->Array.flatMap(e =>
      Route.route(e.payload, ~sourceName=e.sourceName, ~sourceId=e.sourceId, context)
    )
  /** Applies routed events as the runtime's to-do list does: the first writer of
      an id wins, and a resolve completes only a row that already exists. */
  let sweep = (routed: array<AutomationSlice_Route.routed<Spec.todoItem>>) => {
    let rows: array<(string, Spec.todoItem, ref<bool>)> = []
    routed->Array.forEach(r => {
      r.collected->Array.forEach(((id, item)) =>
        if !(rows->Array.some(((seen, _, _)) => seen == id)) {
          rows->Array.push((id, item, ref(false)))
        }
      )
      r.resolved->Option.forEach(id =>
        rows->Array.forEach(
          ((seen, _, done)) =>
            if seen == id {
              done := true
            },
        )
      )
    })
    let todos = rows->Array.filterMap(((id, item, done)) => done.contents ? None : Some((id, item)))
    {todos, commands: todos->Array.filterMap(((id, item)) => Automation.process(id, item))}
  }
  let whenSweep = (events, ~context=testContext) => sweep(routeAll(events, context))
  let thenCommands = (scenario, expected) =>
    scenario.commands == expected
      ? Outcome.pass
      : Outcome.fail(
          EventsMismatch({
            expected: expected->Array.map(encPair),
            actual: scenario.commands->Array.map(encPair),
          }),
        )
  let andThenEvents = (scenario, events, ~context=testContext) => {
    let resolved = routeAll(events, context)->Array.filterMap(r => r.resolved)
    {...scenario, todos: scenario.todos->Array.filter(((id, _)) => !(resolved->Array.includes(id)))}
  }
  let thenScenarioTodos = (scenario, expected) => thenTodos(scenario.todos, expected)
}
