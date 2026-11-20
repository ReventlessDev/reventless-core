// Runs stand-ins against a platform: reads the views that list its things,
// keeps a twin per row, runs each kind's timers at a speed, and posts what the
// twins send to the inbound translations' doors. A client of the public doors
// only: views are read through GraphQL, sends go through the webhook doors.

open ReventlessSeed

/** One post through a door, as the door answered it. */
type sent = {kind: string, id: string, slice: string, body: JSON.t, status: int, at: string}

type t = {
  client: Seed.Client.t,
  doors: array<Standin_Doors.door>,
  commands: Seed.Commands.t,
  kinds: array<Standin_Kind.t>,
  speed: Seed.Pace.speed,
  seed: int,
  refreshMs: int,
  // Called for every post; the runtime keeps the last ones too.
  onSent: sent => unit,
  mutable recent: array<sent>,
  mutable handles: array<NodeTimers.timeout>,
  mutable inFlight: array<promise<unit>>,
  mutable running: bool,
  // Kinds switched off: their timers do not run; by hand they still send.
  mutable off: array<string>,
}

let keep = 200

let make = (
  ~client,
  ~doors,
  ~commands,
  ~kinds,
  ~speed=1.,
  ~seed=1,
  ~refreshMs=60_000,
  ~onSent=_ => (),
  (),
): t => {
  client,
  doors,
  commands,
  kinds,
  speed,
  seed,
  refreshMs,
  onSent,
  recent: [],
  handles: [],
  inFlight: [],
  running: false,
  off: [],
}

/** Whether every send a kind declares has a door and a mutation to check it by;
    the first one that has not. */
let check = (r: t, ~slices: array<string>): result<unit, string> =>
  switch slices->Array.find(slice =>
    r.doors->Standin_Doors.find(~slice)->Option.isNone ||
      r.commands->Seed.Commands.fieldForSlice(~slice)->Option.isNone
  ) {
  | Some(slice) =>
    Error(`no door, or no mutation to check its body by, for the inbound translation ${slice}`)
  | None => Ok()
  }

let send = (r: t): Standin_Kind.sendTo =>
  (~kind, ~id, send) => {
    let work = async () =>
      switch (
        r.doors->Standin_Doors.find(~slice=send.slice),
        r.commands->Seed.Commands.fieldForSlice(~slice=send.slice),
      ) {
      | (Some(door), Some(field)) =>
        switch r.commands->Seed.Commands.checkBody(~field, send.body) {
        | Error(why) => Console.error(`[Standin] ${kind} ${id}: not sent — ${why}`)
        | Ok() =>
          let now = Date.now()
          let answer = try await door->Standin_Doors.post(
            ~body=JSON.stringify(send.body),
            ~nowSeconds=now /. 1000.,
          ) catch {
          | _ => {status: 0, body: "unreachable"}
          }
          let record = {
            kind,
            id,
            slice: send.slice,
            body: send.body,
            status: answer.status,
            at: Date.fromTime(now)->Date.toISOString,
          }
          r.recent = r.recent->Array.concat([record])->Array.slice(~start=-keep)
          r.onSent(record)
          if answer.status >= 300 || answer.status == 0 {
            Console.error(
              `[Standin] ${kind} ${id}: ${send.slice} answered ${answer.status->Int.toString} ${answer.body}`,
            )
          }
        }
      | _ => Console.error(`[Standin] ${kind} ${id}: no door for ${send.slice}`)
      }
    let p = work()
    r.inFlight = r.inFlight->Array.concat([p])
    p->Promise.thenResolve(() => r.inFlight = r.inFlight->Array.filter(q => q !== p))
  }

let rowId = (row: JSON.t, ~idField: string): option<string> =>
  switch row->Seed.Commands.get(idField) {
  | Some(String(id)) => Some(id)
  | _ => None
  }

/** Reads the views again: a row with no twin gets one, a twin whose row is gone
    is forgotten. */
let refresh = async (r: t): unit => {
  let reads = r.kinds->Array.map(async kind =>
    switch kind.view {
    | None => kind.sync(~seed=r.seed, [])->ignore
    | Some((view, idField, selection)) =>
      switch await r.client->Seed.Client.queryAllNodes(~field=view, ~selection) {
      | rows =>
        kind.sync(
          ~seed=r.seed,
          rows->Array.filterMap(row => rowId(row, ~idField)->Option.map(id => (id, row))),
        )->ignore
      | exception _ => Console.error(`[Standin] ${kind.name}: ${view} could not be read`)
      }
    }
  )
  let _ = await Promise.all(reads)
}

/** Starts every kind's timers, at the run's speed, after a first read of the views. */
let start = async (r: t): unit =>
  if !r.running {
    r.running = true
    await refresh(r)
    let timers = r.kinds->Array.flatMap(kind =>
      kind.timers->Array.map(((timer, everyMs)) =>
        NodeTimers.setInterval(
          () =>
            if r.running && !(r.off->Array.includes(kind.name)) {
              kind.fire(~timer, ~now=Date.make(), send(r))->ignore
            },
          Seed.Pace.realMs(r.speed, everyMs)->Math.Int.max(1),
        )
      )
    )
    let reread = NodeTimers.setInterval(() =>
      if r.running {
        refresh(r)->ignore
      }
    , r.refreshMs)
    r.handles = timers->Array.concat([reread])
  }

/** Ends every timer and waits for the sends already under way: none is left half done. */
let stop = async (r: t): unit => {
  r.running = false
  r.handles->Array.forEach(NodeTimers.clearInterval)
  r.handles = []
  let _ = await Promise.all(r.inFlight)
}

/** Sends one of a kind's messages for one twin, now. */
let byHand = (r: t, ~kind: string, ~id: string, ~message: string, ~fields=Dict.make()) =>
  switch r.kinds->Array.find(k => k.name == kind) {
  | None => Promise.resolve(Error(`no kind ${kind}`))
  | Some(k) => k.byHand(~id, ~message, ~fields, ~now=Date.make(), send(r))
  }

/** Every kind with its twins and their state. */
let state = (r: t): array<(string, array<(string, JSON.t)>)> =>
  r.kinds->Array.map(k => (k.name, k.twins()))

/** Tells one twin something, as the app's devices capability does: accepted,
    refused with its reason, or not reachable when no stand-in plays it. */
let tell = (r: t, ~kind: string, ~instance: string, ~message: string, ~body: JSON.t) =>
  switch r.kinds->Array.find(k => k.name == kind) {
  | None => Promise.resolve(Standin_Kind.NotReachable(`no stand-in plays ${kind}`))
  | Some(k) => k.tell(~id=instance, ~message, ~body, ~now=Date.make(), send(r))
  }

/** Changes a kind's misbehaviour while it runs. */
let setRates = (r: t, ~kind: string, rates: Standin_Kind.rates): result<unit, string> =>
  switch r.kinds->Array.find(k => k.name == kind) {
  | None => Error(`no kind ${kind}`)
  | Some(k) => Ok(k.setRates(rates))
  }

/** Silences one twin on purpose, for `ticks` of its timers. */
let silence = (r: t, ~kind: string, ~id: string, ~ticks: int): result<unit, string> =>
  switch r.kinds->Array.find(k => k.name == kind) {
  | None => Error(`no kind ${kind}`)
  | Some(k) => k.silence(~id, ~ticks)
  }

/** Switches a kind's timers on or off; by hand it still sends. */
let switchKind = (r: t, ~kind: string, ~on: bool): result<unit, string> =>
  switch r.kinds->Array.find(k => k.name == kind) {
  | None => Error(`no kind ${kind}`)
  | Some(_) =>
    r.off = on ? r.off->Array.filter(k => k != kind) : r.off->Array.concat([kind])
    Ok()
  }

let isOn = (r: t, ~kind: string): bool => !(r.off->Array.includes(kind))

/** The last sends, oldest first. */
let recent = (r: t): array<sent> => r.recent
