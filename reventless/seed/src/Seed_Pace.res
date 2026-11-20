// How long a run waits before each command it sends.
//
// A pace is a value, not sleeps written into a data set, so the same run plays
// faster, slower or at full speed without being edited. A jittered pace draws
// each gap from a generator seeded by the send's index, so it repeats exactly.

type t = {
  // What the pace was read from, for the run's heading.
  text: string,
  // The wait in milliseconds before the send with this index (the first is 0).
  gapMs: int => int,
}

let fixed = (~text, ms: int): t => {text, gapMs: i => i == 0 ? 0 : ms}

// Arrivals at a mean gap, spaced as a random process would space them: an
// exponential gap, capped at ten times the mean so one draw cannot stall a run.
let jittered = (~text, ~meanMs: float): t => {
  text,
  gapMs: i =>
    if i == 0 {
      0
    } else {
      let u = Seed_Random.make(~seed=0x5eed->Int.bitwiseXor(i * 0x9e3779b))->Seed_Random.float
      let gap = -.meanMs *. Math.log(1. -. u)
      Math.min(gap, meanMs *. 10.)->Math.round->Float.toInt
    },
}

let unitMs = (u: string): option<float> =>
  switch u {
  | "ms" => Some(1.)
  | "s" | "sec" => Some(1000.)
  | "m" | "min" => Some(60000.)
  | "h" => Some(3600000.)
  | _ => None
  }

// Strict: `Float.fromString` reads "2s" as 2.
let number = (s: string): option<float> =>
  switch /^[0-9]*\.?[0-9]+$/->RegExp.test(s) ? Float.fromString(s) : None {
  | Some(n) if n > 0. => Some(n)
  | _ => None
  }

/**
 * Reads a pace: a gap (`500ms`, `2s`, `1.5min`) or a rate (`30/min`, `2/s`,
 * `100/h`); a trailing `~` makes the gaps random around that mean.
 */
let parse = (raw: string): result<t, string> => {
  let text = raw->String.trim
  let (body, jitter) =
    text->String.endsWith("~")
      ? (text->String.slice(~start=0, ~end=String.length(text) - 1), true)
      : (text, false)
  let meanMs = switch body->String.split("/") {
  | [count, per] =>
    switch (number(count), unitMs(per)) {
    | (Some(n), Some(ms)) => Some(ms /. n)
    | _ => None
    }
  | [gap] =>
    switch gap->String.match(/^([0-9.]+)([a-z]+)$/) {
    | Some([_, Some(n), Some(u)]) =>
      switch (number(n), unitMs(u)) {
      | (Some(n), Some(ms)) => Some(n *. ms)
      | _ => None
      }
    | _ => None
    }
  | _ => None
  }
  switch meanMs {
  | Some(mean) if jitter => Ok(jittered(~text, ~meanMs=mean))
  | Some(mean) => Ok(fixed(~text, mean->Math.round->Float.toInt))
  | None =>
    Error(
      `"${raw}" is not a pace — expected a gap such as 2s or 500ms, or a rate such as 30/min, with an optional trailing ~ for random gaps`,
    )
  }
}

/** The wait the first `count` sends add up to. */
let totalMs = (pace: t, ~count: int): int =>
  Array.fromInitializer(~length=count, i => pace.gapMs(i))->Array.reduce(0, (a, b) => a + b)

// ── Speed ───────────────────────────────────────────────────────────────────
//
// A pace spaces sends; a speed shortens time itself, for a client whose timers
// stand for simulated intervals (a reading every simulated minute). Every time
// such a client sends is still the true one.

/** How many simulated milliseconds pass in one real one; `1.` is real time. */
type speed = float

/** Reads a speed: `10x`, `0.5x` or a bare number. */
let parseSpeed = (raw: string): result<speed, string> => {
  let text = raw->String.trim
  let body = text->String.endsWith("x") ? text->String.slice(~start=0, ~end=-1) : text
  switch number(body) {
  | Some(n) => Ok(n)
  | None => Error(`"${raw}" is not a speed — expected a factor such as 10x or 0.5x`)
  }
}

/** The real wait for a simulated interval at `speed`. */
let realMs = (speed: speed, simulatedMs: float): int =>
  (simulatedMs /. speed)->Math.round->Float.toInt
