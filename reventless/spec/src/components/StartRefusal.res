/***
Why a platform refuses to start, as a value.

A check that stops a start (a `@partitionTag` inference contradicts, a scope
marker on the wrong key, a store something else is serving, a role nothing
honours) makes one `refusal` per finding, with the fields it found. The sentence
people read is made from that value, so the message stays the same while a
program can read the code and the fields instead of parsing the sentence.

The refusal travels on the error the start throws, in its own `refusal`
property, so a caller that loaded the app some other way (a dynamic import of
its start module) still reads it back with [ofError].
*/

/** Each kind of refusal's stable code: kebab-case, never reused for another
    meaning. `Unknown` is for an error that carries no refusal. */
module Code = {
  type t =
    | @as("partition-contradiction") PartitionContradiction
    | @as("partition-unreachable") PartitionUnreachable
    | @as("scope-contradiction") ScopeContradiction
    | @as("no-partition-key") NoPartitionKey
    | @as("store-in-use") StoreInUse
    | @as("roles-unhonoured") RolesUnhonoured
    | @as("unknown") Unknown

  let toString = (code: t): string => (code :> string)
}

/** What inference makes of a slice whose `@partitionTag` it contradicts. */
type inference =
  /** It derives this key from the slice graph. */
  | Derives(string)
  /** It derives no key; these are the keys it could not choose between. */
  | Candidates(array<string>)

type refusal =
  /** The `@partitionTag` names a key the slice only reads as a reference to
      another entity. `arms` are the consumed events a `@crossPartition` marker
      by the named key would let the slice read, when that is a way out. */
  | PartitionContradiction({
      slice: string,
      named: string,
      inference: inference,
      arms: array<string>,
    })
  /** The `@partitionTag` decides a partition inference leaves open, but the slice's
      read by that key misses these events, stored under another key. */
  | PartitionUnreachable({slice: string, named: string, missed: array<string>})
  /** A consumed event marks a key `@crossPartition` that is not the slice's partition. */
  | ScopeContradiction({slice: string, eventType: string, marked: string, partition: string})
  /** No partition key can be inferred for the slice, for this reason. */
  | NoPartitionKey({slice: string, reason: string})
  /** A reset would wipe a store a running platform is serving. */
  | StoreInUse({path: string, app: string, port: int, pid: int})
  /** A role is declared self-service or by invitation, and nothing here honours it. */
  | RoleUnhonoured({plugin: string, role: string, why: string})

/** One refused start: the findings of one check, and the component it refused. */
type t = {
  component?: string,
  refusals: array<refusal>,
}

let code = (r: refusal): Code.t =>
  switch r {
  | PartitionContradiction(_) => PartitionContradiction
  | PartitionUnreachable(_) => PartitionUnreachable
  | ScopeContradiction(_) => ScopeContradiction
  | NoPartitionKey(_) => NoPartitionKey
  | StoreInUse(_) => StoreInUse
  | RoleUnhonoured(_) => RolesUnhonoured
  }

/** The slice a finding is about, for the findings that are about one. */
let slice = (r: refusal): option<string> =>
  switch r {
  | PartitionContradiction({slice})
  | PartitionUnreachable({slice})
  | ScopeContradiction({slice})
  | NoPartitionKey({slice}) =>
    Some(slice)
  | StoreInUse(_) | RoleUnhonoured(_) => None
  }

let markHint = (named, arms) =>
  `mark ${named} @crossPartition on ${arms->Array.join(
      "/",
    )} in the slice's consumedEvent to read it across partitions`

/** The sentence one finding says. */
let describe = (r: refusal): string =>
  switch r {
  | PartitionContradiction({named, inference, arms}) =>
    let way = arms == [] ? "" : `, or ${markHint(named, arms)}`
    switch inference {
    | Derives(derived) =>
      `@partitionTag names ${named}, but inference derives ${derived} from the slice graph — ${named} is read from another entity. Remove the annotation, or move it to ${derived}${way}.`
    | Candidates(candidates) =>
      `@partitionTag names ${named}, which this slice only reads as a reference to another entity (candidates: ${candidates->Array.join(
          ", ",
        )}). Move the annotation to the slice's own key${way}.`
    }
  | PartitionUnreachable({named, missed}) =>
    `@partitionTag ${named} decides the partition, but ${missed->Array.join(
        "/",
      )} carry ${named} and are stored under another key, so the slice's read by ${named} never finds them. Partition their writers by ${named}, or ${markHint(
        named,
        missed,
      )}.`
  | ScopeContradiction({slice, eventType, marked, partition}) =>
    `${eventType} marks ${marked} @crossPartition, but ${slice} is partitioned by ${partition}. A consumed arm marks only the slice's own key; a read of another entity's ${marked} across partitions follows from the slice graph, or from @crossPartition on the event that writes it. Remove the marker.`
  | NoPartitionKey({reason}) => reason
  | StoreInUse({path, app, port, pid}) =>
    `refusing to reset ${path}: it is the store of ${app} running at :${port->Int.toString} (pid ${pid->Int.toString}). ` ++ `Stop that platform first, or start this one without ?reset.`
  | RoleUnhonoured({plugin, role, why}) => `${plugin}: ${role} ${why}`
  }

/** The message of the whole refusal, as the error carries it. One refused start
    holds the findings of one check, so the first finding says which check
    words the message. */
let message = (t: t): string => {
  let component = t.component->Option.getOr("")
  let bySlice = () =>
    t.refusals
    ->Array.map(r => `${r->slice->Option.getOr("")}: ${r->describe}`)
    ->Array.join(" | ")
  switch t.refusals->Array.get(0) {
  | None => ""
  | Some(PartitionContradiction(_) | PartitionUnreachable(_)) =>
    `DCB partition contradiction (${component}): ${bySlice()}`
  | Some(ScopeContradiction(_)) => `DCB scope contradiction (${component}): ${bySlice()}`
  | Some(NoPartitionKey(_)) => `DCB partition key cannot be inferred — ${bySlice()}`
  | Some(StoreInUse(_)) => t.refusals->Array.map(describe)->Array.join(" ")
  | Some(RoleUnhonoured(_)) =>
    `Admission this platform cannot honor — the people it is for could not get in:\n` ++
    t.refusals->Array.map(r => `  ${r->describe}`)->Array.join("\n")
  }
}

// ─── JSON ────────────────────────────────────────────────────────────────────

let strings = (xs: array<string>) => xs->Array.map(JSON.Encode.string)->JSON.Encode.array

/** One finding as JSON: its code, its sentence, and its fields. */
let refusalToJson = (r: refusal): JSON.t => {
  let fields = switch r {
  | PartitionContradiction({slice, named, inference, arms}) => [
      ("slice", JSON.Encode.string(slice)),
      ("named", JSON.Encode.string(named)),
      switch inference {
      | Derives(derived) => ("derived", JSON.Encode.string(derived))
      | Candidates(candidates) => ("candidates", strings(candidates))
      },
      ("arms", strings(arms)),
    ]
  | PartitionUnreachable({slice, named, missed}) => [
      ("slice", JSON.Encode.string(slice)),
      ("named", JSON.Encode.string(named)),
      ("missed", strings(missed)),
    ]
  | ScopeContradiction({slice, eventType, marked, partition}) => [
      ("slice", JSON.Encode.string(slice)),
      ("eventType", JSON.Encode.string(eventType)),
      ("marked", JSON.Encode.string(marked)),
      ("partition", JSON.Encode.string(partition)),
    ]
  | NoPartitionKey({slice, reason}) => [
      ("slice", JSON.Encode.string(slice)),
      ("reason", JSON.Encode.string(reason)),
    ]
  | StoreInUse({path, app, port, pid}) => [
      ("path", JSON.Encode.string(path)),
      ("app", JSON.Encode.string(app)),
      ("port", JSON.Encode.int(port)),
      ("pid", JSON.Encode.int(pid)),
    ]
  | RoleUnhonoured({plugin, role, why}) => [
      ("plugin", JSON.Encode.string(plugin)),
      ("role", JSON.Encode.string(role)),
      ("why", JSON.Encode.string(why)),
    ]
  }
  [
    ("code", r->code->Code.toString->JSON.Encode.string),
    ("message", r->describe->JSON.Encode.string),
  ]
  ->Array.concat(fields)
  ->Dict.fromArray
  ->JSON.Encode.object
}

/** A refused start as JSON: its message, the component, and each finding. */
let toJson = (t: t): JSON.t =>
  [("message", t->message->JSON.Encode.string)]
  ->Array.concat(t.component->Option.mapOr([], c => [("component", JSON.Encode.string(c))]))
  ->Array.concat([("refusals", t.refusals->Array.map(refusalToJson)->JSON.Encode.array)])
  ->Dict.fromArray
  ->JSON.Encode.object

/** What [toJson] says for a refusal that came only as a message: one finding,
    coded `unknown`. */
let unknownToJson = (message: string): JSON.t => {
  let text = JSON.Encode.string(message)
  Dict.fromArray([
    ("message", text),
    (
      "refusals",
      JSON.Encode.array([
        Dict.fromArray([
          ("code", Code.Unknown->Code.toString->JSON.Encode.string),
          ("message", text),
        ])->JSON.Encode.object,
      ]),
    ),
  ])->JSON.Encode.object
}

// ─── On the error ────────────────────────────────────────────────────────────

@set external setRefusal: (JsError.t, t) => unit = "refusal"
@get external refusalProperty: JsExn.t => Nullable.t<t> = "refusal"

/** The error a refused start throws: [message] as its message, the refusal in
    its `refusal` property. */
let error = (t: t): JsError.t => {
  let e = JsError.make(t->message)
  e->setRefusal(t)
  e
}

let throw = (t: t): 'a => t->error->JsError.throw

/** The refusal an error carries, if it carries one. */
let ofError = (e: JsExn.t): option<t> =>
  switch e->(Obj.magic: JsExn.t => Nullable.t<JsExn.t>)->Nullable.toOption {
  | Some(err) if Type.typeof(err) == #object =>
    err
    ->refusalProperty
    ->Nullable.toOption
    ->Option.filter(r => Type.typeof(r) == #object && Array.isArray(r.refusals))
  | _ => None
  }
