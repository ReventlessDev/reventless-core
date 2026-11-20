// A kind of thing or service a stand-in plays, defined once with its state, its
// timers and the messages it may send, and erased to `t` so one runtime holds
// kinds whose states differ.
//
// A thing has one twin per row of the app's view that lists it; a service has
// one. Every twin draws its random values from its own generator, seeded by the
// run's seed, the kind and the twin's id, so a run started with one seed sends
// the same values whatever order the timers fire in.

open ReventlessSeed

/** A message a twin sends: the body an inbound translation's door takes. */
type send = {slice: string, body: JSON.t}

/** What a twin's step gives back: its next state, and what it sends. */
type step<'state> = {state: 'state, sends: array<send>}

/** A timer, every `everyMs` of simulated time. `elapsedMs` is the simulated
    interval since it last ran; `now` the true time, which is the time a send carries. */
type timer<'state> = {
  name: string,
  everyMs: float,
  run: (
    ~id: string,
    'state,
    ~elapsedMs: float,
    ~random: Seed.Random.t,
    ~now: Date.t,
  ) => step<'state>,
}

/** A message a person may send for one twin by hand, with fields given or filled
    from its state. */
type message<'state> = {
  name: string,
  build: (~id: string, 'state, ~fields: dict<JSON.t>, ~now: Date.t) => result<step<'state>, string>,
}

/** What a twin does when the app tells it something: its next state and what
    it sends, or a refusal with its reason. */
type told<'state> = {
  message: string,
  run: (~id: string, 'state, ~body: JSON.t, ~now: Date.t) => result<step<'state>, string>,
}

/** How a twin answers being told something; `Devices.answer` on the platform's side. */
type answer =
  | Accepted
  | Refused(string)
  | NotReachable(string)

type thing<'state> = {
  name: string,
  // The app's view that lists the things, its id field, and what to read of a row.
  view: string,
  idField: string,
  selection: string,
  init: (~id: string, ~row: JSON.t, ~random: Seed.Random.t) => 'state,
  timers: array<timer<'state>>,
  messages: array<message<'state>>,
  // What it understands when told something; absent, it refuses everything.
  told?: array<told<'state>>,
  // The state as the platform serves it, for a person to read.
  describe: 'state => JSON.t,
}

type service<'state> = {
  name: string,
  init: (~random: Seed.Random.t) => 'state,
  timers: array<timer<'state>>,
  messages: array<message<'state>>,
  told?: array<told<'state>>,
  describe: 'state => JSON.t,
}

// ── Erased ──────────────────────────────────────────────────────────────────

/** Where a step's sends go; the runtime's. */
type sendTo = (~kind: string, ~id: string, send) => promise<unit>

type t = {
  name: string,
  // Some for a thing: where its twins come from.
  view: option<(string, string, string)>,
  timers: array<(string, float)>,
  messages: array<string>,
  // Makes a twin for every row that has none, forgets every twin whose row is
  // gone; the ids added and removed.
  sync: (~seed: int, array<(string, JSON.t)>) => (array<string>, array<string>),
  // Runs a timer for every twin, each twin's sends in order.
  fire: (~timer: string, ~now: Date.t, sendTo) => promise<unit>,
  byHand: (
    ~id: string,
    ~message: string,
    ~fields: dict<JSON.t>,
    ~now: Date.t,
    sendTo,
  ) => promise<result<unit, string>>,
  // Answers being told something, for one twin; its sends go out after.
  tell: (~id: string, ~message: string, ~body: JSON.t, ~now: Date.t, sendTo) => promise<answer>,
  twins: unit => array<(string, JSON.t)>,
}

/** A string's 32-bit hash, so a twin's generator is seeded by its id. */
let hash = (text: string): int => {
  let h = ref(5381)
  for i in 0 to text->String.length - 1 {
    h := (h.contents * 33)->Int.bitwiseXor(text->String.charCodeAt(i)->Option.getOr(0))
  }
  h.contents
}

let randomFor = (~seed: int, ~kind: string, ~id: string): Seed.Random.t =>
  Seed.Random.make(~seed=seed->Int.bitwiseXor(hash(`${kind}/${id}`)))

type twin<'state> = {
  mutable state: 'state,
  random: Seed.Random.t,
  // The twin's sends, one after another.
  mutable queue: promise<unit>,
}

let erase = (
  ~name: string,
  ~view: option<(string, string, string)>,
  ~init: (~id: string, ~row: JSON.t, ~random: Seed.Random.t) => 'state,
  ~timers: array<timer<'state>>,
  ~messages: array<message<'state>>,
  ~told: array<told<'state>>,
  ~describe: 'state => JSON.t,
): t => {
  let twins: dict<twin<'state>> = Dict.make()
  let deliver = (twin: twin<'state>, ~id, sends: array<send>, sendTo: sendTo) => {
    let next = twin.queue->Promise.then(async () =>
      for i in 0 to sends->Array.length - 1 {
        await sendTo(~kind=name, ~id, sends->Array.getUnsafe(i))
      }
    )
    twin.queue = next->Promise.catch(_ => Promise.resolve())
    next
  }
  {
    name,
    view,
    timers: timers->Array.map(t => (t.name, t.everyMs)),
    messages: messages->Array.map(m => m.name),
    sync: (~seed, rows) => {
      let present = rows->Array.map(((id, _)) => id)
      let removed = twins->Dict.keysToArray->Array.filter(id => !(present->Array.includes(id)))
      removed->Array.forEach(id => twins->Dict.delete(id))
      let added = rows->Array.filterMap(((id, row)) =>
        switch twins->Dict.get(id) {
        | Some(_) => None
        | None =>
          let random = randomFor(~seed, ~kind=name, ~id)
          twins->Dict.set(id, {state: init(~id, ~row, ~random), random, queue: Promise.resolve()})
          Some(id)
        }
      )
      (added, removed)
    },
    fire: async (~timer, ~now, sendTo) =>
      switch timers->Array.find(t => t.name == timer) {
      | None => ()
      | Some(t) =>
        let runs =
          twins
          ->Dict.toArray
          ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
          ->Array.map(((id, twin)) => {
            let step = t.run(~id, twin.state, ~elapsedMs=t.everyMs, ~random=twin.random, ~now)
            twin.state = step.state
            deliver(twin, ~id, step.sends, sendTo)
          })
        let _ = await Promise.all(runs)
      },
    byHand: async (~id, ~message, ~fields, ~now, sendTo) =>
      switch (twins->Dict.get(id), messages->Array.find(m => m.name == message)) {
      | (None, _) => Error(`${name} has no instance ${id}`)
      | (_, None) => Error(`${name} sends no message ${message}`)
      | (Some(twin), Some(m)) =>
        switch m.build(~id, twin.state, ~fields, ~now) {
        | Error(why) => Error(why)
        | Ok(step) =>
          twin.state = step.state
          await deliver(twin, ~id, step.sends, sendTo)
          Ok()
        }
      },
    tell: async (~id, ~message, ~body, ~now, sendTo) =>
      switch (twins->Dict.get(id), told->Array.find(t => t.message == message)) {
      | (None, _) => NotReachable(`${name} ${id} is not played by any stand-in`)
      | (_, None) => Refused(`${name} does not understand ${message}`)
      | (Some(twin), Some(t)) =>
        switch t.run(~id, twin.state, ~body, ~now) {
        | Error(why) => Refused(why)
        | Ok(step) =>
          twin.state = step.state
          deliver(twin, ~id, step.sends, sendTo)->ignore
          Accepted
        }
      },
    twins: () =>
      twins
      ->Dict.toArray
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
      ->Array.map(((id, twin)) => (id, describe(twin.state))),
  }
}

/** A kind of thing, one twin per row of `view`. */
let thing = (def: thing<'state>): t =>
  erase(
    ~name=def.name,
    ~view=Some((def.view, def.idField, def.selection)),
    ~init=def.init,
    ~timers=def.timers,
    ~messages=def.messages,
    ~told=def.told->Option.getOr([]),
    ~describe=def.describe,
  )

/** A kind of service: one twin, named as the kind. */
let service = (def: service<'state>): t => {
  let kind = erase(
    ~name=def.name,
    ~view=None,
    ~init=(~id as _, ~row as _, ~random) => def.init(~random),
    ~timers=def.timers,
    ~messages=def.messages,
    ~told=def.told->Option.getOr([]),
    ~describe=def.describe,
  )
  {
    ...kind,
    sync: (~seed, _) => kind.sync(~seed, [(def.name, JSON.Encode.null)]),
  }
}
