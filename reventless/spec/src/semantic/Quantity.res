/**
A number in a declared quantity and unit: `delivered` holds energy in kWh.

The value is a plain `float` in the field's unit, so typing an existing number
field changes nothing stored. What it measures rides in the schema: the semantic
`quantity` with the unit as its detail, and the quantity's definition (its units,
each unit's factor and words) as metadata a plugin's structure lists once.

A quantity is defined once. Its first unit is the one the factors count from,
so its factor is 1; every other unit says how many of the first it is. Units
convert by these factors and nothing else, which is why a factor, once a value
is stored in its unit, never changes.

@example
```rescript
@schema type state = {
  sessionId: string,
  delivered: @s.matches(Reventless.Energy.kilowattHour) float,
}
```
*/
/** The value: a number in the field's declared unit. */
type t = float

/** One unit of a quantity: its code as written (`kWh`), how many of the
    quantity's first unit it is, and its name in English words. */
@schema
type unitDef = {code: string, factor: float, words: string, plural: string}

/** How a quantity is another held over time: energy is power held for a
    duration. The quantity's first unit is the other's first unit held for
    `seconds` seconds, so energy's is `{quantity: "power", seconds: 3600.0}`: a
    watt held for an hour is a watt-hour. */
@schema
type overTime = {quantity: string, seconds: float}

/** A quantity: its name (`energy`), whether two values may be summed (energy
    delivered adds up, a temperature does not), its units, first the one the
    factors count from, and, where it is another held over time, which. */
@schema
type def = {name: string, adds: bool, units: array<unitDef>, overTime?: overTime}

// ── The standard set ──────────────────────────────────────────────────────────

let energy: def = {
  name: "energy",
  adds: true,
  units: [
    {code: "Wh", factor: 1.0, words: "watt-hour", plural: "watt-hours"},
    {code: "kWh", factor: 1e3, words: "kilowatt-hour", plural: "kilowatt-hours"},
    {code: "MWh", factor: 1e6, words: "megawatt-hour", plural: "megawatt-hours"},
    {code: "GWh", factor: 1e9, words: "gigawatt-hour", plural: "gigawatt-hours"},
  ],
  overTime: {quantity: "power", seconds: 3600.0},
}

// Power adds up as energy does: the loads on one connection sum to its load.
let power: def = {
  name: "power",
  adds: true,
  units: [
    {code: "W", factor: 1.0, words: "watt", plural: "watts"},
    {code: "kW", factor: 1e3, words: "kilowatt", plural: "kilowatts"},
    {code: "MW", factor: 1e6, words: "megawatt", plural: "megawatts"},
  ],
}

/** The quantities core ships, so a tool reading a definition knows which need
    no declaration. A plugin's own quantity never takes one of these names. */
let standard: array<def> = [energy, power]

let isStandardName = (name: string): bool => standard->Array.some(q => q.name == name)

// ── Declaring one ─────────────────────────────────────────────────────────────

// The same quantity, whether or not it says what it is held over time: a
// quantity's module is built from its name and units alone.
let sameUnits = (a: def, b: def): bool =>
  a.name == b.name &&
  a.adds == b.adds &&
  a.units == b.units &&
  (a.overTime == None || b.overTime == None || a.overTime == b.overTime)

/** A quantity as a plugin declares it, checked: at least one unit, the first
    with factor 1, every factor finite and positive, no code twice, and no
    standard quantity's name unless it is that quantity unchanged, which is then
    core's own, with what it is held over time. Only core's quantities say that:
    a plugin's own is never another held over time. */
let declare = (q: def): result<def, string> => {
  let codes = q.units->Array.map(u => u.code)
  let twice = codes->Array.filterWithIndex((code, i) => codes->Array.indexOf(code) != i)
  switch standard->Array.find(s => sameUnits(s, q)) {
  | Some(s) => Ok(s)
  | None if q.name == "" => Error("a quantity needs a name")
  | None if isStandardName(q.name) =>
    Error(
      `"${q.name}" is a quantity core ships; a plugin adds quantities and never redefines ` ++
      `one, since a changed factor would change what stored numbers mean. Use ` ++
      `core's ${q.name}, or give this quantity another name.`,
    )
  | None if q.overTime != None =>
    Error(`the quantity "${q.name}" says it is another held over time; only core's energy does`)
  | None =>
    switch q.units {
    | [] => Error(`the quantity "${q.name}" needs at least one unit`)
    | units =>
      switch units->Array.find(u => !Float.isFinite(u.factor) || u.factor <= 0.0) {
      | Some(u) =>
        Error(
          `the unit ${u.code} of "${q.name}" needs a factor greater than zero, got ${Float.toString(
              u.factor,
            )}`,
        )
      | None =>
        if (units->Array.getUnsafe(0)).factor != 1.0 {
          Error(
            `the first unit of "${q.name}" is the one the factors count from, so its factor is 1`,
          )
        } else if twice->Array.length > 0 {
          Error(`the quantity "${q.name}" names the unit ${twice->Array.join(", ")} twice`)
        } else {
          Ok(q)
        }
      }
    }
  }
}

/** Definitions that share a name but differ, each pair once: a plugin whose
    fields disagree on what `volume` is. */
let conflicts = (defs: array<def>): array<(def, def)> =>
  defs->Array.flatMapWithIndex((a, i) =>
    defs
    ->Array.slice(~start=i + 1)
    ->Array.filter(b => a.name == b.name && a != b)
    ->Array.map(b => (a, b))
  )

let unitOf = (q: def, code: string): option<unitDef> => q.units->Array.find(u => u.code == code)

// ── Converting ────────────────────────────────────────────────────────────────

/** A value from one of the quantity's units into another, by their factors.
    Divides or multiplies by the ratio of the two, the larger over the smaller, so
    a whole-number factor stays whole: 1240 kWh is 1.24 MWh. */
let convert = (q: def, value: float, ~from: string, ~to: string): result<float, string> =>
  switch (unitOf(q, from), unitOf(q, to)) {
  | (Some(f), Some(t)) =>
    Ok(f.factor >= t.factor ? value *. (f.factor /. t.factor) : value /. (t.factor /. f.factor))
  | (None, _) => Error(`${from} is not a unit of ${q.name}`)
  | (_, None) => Error(`${to} is not a unit of ${q.name}`)
  }

// ── Held over time ────────────────────────────────────────────────────────────

/** How many seconds of `rate`, in its first unit, make one of `total`'s first
    unit: 3600 for energy over power. Refused where `total` is not `rate` held
    over time. */
let secondsOver = (~total: def, ~rate: def): result<float, string> =>
  switch total.overTime {
  | Some({quantity, seconds}) if quantity == rate.name => Ok(seconds)
  | _ => Error(`${total.name} is not ${rate.name} held over time`)
  }

/** A rate held constant over a duration, as its total: 22 kW for half an hour
    is 11 kWh. Converts through each quantity's first unit. A negative duration
    is refused; over none, the total is zero. */
let accumulate = (
  ~total: def,
  ~rate: def,
  value: float,
  ~from: string,
  ~over: Duration.t,
  ~to: string,
): result<float, string> =>
  if over < 0 {
    Error(`a duration cannot be negative, got ${Int.toString(over)} seconds`)
  } else {
    secondsOver(~total, ~rate)->Result.flatMap(seconds =>
      convert(
        rate,
        value,
        ~from,
        ~to=(rate.units->Array.getUnsafe(0)).code,
      )->Result.flatMap(first =>
        convert(
          total,
          first *. Int.toFloat(over) /. seconds,
          ~from=(total.units->Array.getUnsafe(0)).code,
          ~to,
        )
      )
    )
  }

/** A total over a duration, as the rate that held constant gives it: 11 kWh
    over half an hour is 22 kW on average. Converts through each quantity's first
    unit. A duration of zero or less has no rate and is refused. */
let average = (
  ~total: def,
  ~rate: def,
  value: float,
  ~from: string,
  ~over: Duration.t,
  ~to: string,
): result<float, string> =>
  if over <= 0 {
    Error(`an average needs a duration longer than zero, got ${Int.toString(over)} seconds`)
  } else {
    secondsOver(~total, ~rate)->Result.flatMap(seconds =>
      convert(
        total,
        value,
        ~from,
        ~to=(total.units->Array.getUnsafe(0)).code,
      )->Result.flatMap(first =>
        convert(
          rate,
          first *. seconds /. Int.toFloat(over),
          ~from=(rate.units->Array.getUnsafe(0)).code,
          ~to,
        )
      )
    )
  }

// ── The schema ────────────────────────────────────────────────────────────────

/** Where a schema keeps the quantity it measures, beside the semantic marker
    that names only the quantity and the unit. */
let defId: S.Metadata.Id.t<def> = S.Metadata.Id.make(~namespace="reventless", ~name="quantity")

/** Validate a number as a value of a quantity. A quantity may be negative
    (energy fed back into the grid); the sign is the field's own rule. */
let fromFloat = (raw: float): result<t, string> =>
  Float.isFinite(raw) ? Ok(raw) : Error(`a quantity is a finite number, got ${Float.toString(raw)}`)

/** The schema of a field holding `q` in the unit `code`. Refuses a code the
    quantity does not have, at the declaration. */
let schemaIn = (q: def, code: string): S.t<t> =>
  switch unitOf(q, code) {
  | None => JsError.throwWithMessage(`${code} is not a unit of ${q.name}`)
  | Some(_) =>
    S.float
    ->S.refine(value => Float.isFinite(value), ~error=`expected a number in ${code}`)
    ->Semantic.mark(~id=Semantic.Id.quantity, ~payload=InUnit({quantity: q.name, unit: code}))
    ->S.Metadata.set(~id=defId, q)
  }

/** The quantity a schema measures, read through an optional field's wrapper. */
let rec defOf = (schema: S.t<unknown>): option<def> =>
  switch S.Metadata.get(schema, ~id=defId) {
  | Some(_) as found => found
  | None => schema->Semantic.unwrapOptional->Option.flatMap(defOf)
  }

/** The quantity and unit a field holds, as its marker says: a quantity or a
    price per one of its units. Read on a list's elements too. */
let rec fieldUnit = (schema: S.t<unknown>): option<(def, string)> => {
  let own = switch (Semantic.getFrom(schema), defOf(schema)) {
  | (Some({payload: InUnit({unit}) | PerUnit({unit})}), Some(q)) => Some((q, unit))
  | _ => None
  }
  switch own {
  | Some(_) => own
  | None =>
    switch schema->Semantic.unwrapOptional->Option.getOr(schema) {
    | Array({additionalItems: Schema(item)}) => fieldUnit(item)
    | _ => None
    }
  }
}

/** The quantity and unit a unit's schema stands for, refusing a schema that is
    not one, at the declaration: what `PricePer` and `charge` are handed. */
let unitOfSchema = (schema: S.t<t>): (def, string) =>
  switch schema->S.castToUnknown->fieldUnit {
  | Some(found) => found
  | None =>
    JsError.throwWithMessage("expected a quantity's unit, such as Reventless.Energy.kilowattHour")
  }

/** A quantity's module: `def` and the schema per unit. What `Energy` and
    `Power` are, and what a plugin's own quantity is built with. */
module type Def = {
  let name: string
  let adds: bool
  let units: array<unitDef>
}

module Make = (D: Def) => {
  type t = t
  let def: def = switch declare({name: D.name, adds: D.adds, units: D.units}) {
  | Ok(q) => q
  | Error(reason) => JsError.throwWithMessage(reason)
  }
  /** The schema of a field in the unit `code`. */
  let in_ = (code: string): S.t<t> => schemaIn(def, code)
  let convert = (value: t, ~from: string, ~to: string): result<t, string> =>
    convert(def, value, ~from, ~to)
}
