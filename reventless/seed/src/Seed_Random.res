// Deterministic pseudo-randomness for reproducible datasets.
//
// A seeded generator rather than `Math.random`, so two runs against a fresh
// store produce identical data — which is what makes a seeded store usable as a
// baseline for screenshots or comparison.

@scope("Math") @val external imul: (int, int) => int = "imul"

type t = {mutable state: int}

let make = (~seed: int): t => {state: seed}


/** mulberry32 — small, fast, and stable across JS engines and Node versions. */
let float = (r: t): float => {
  r.state = (r.state + 0x6d2b79f5)->Int.bitwiseOr(0)
  let a = r.state
  let b = imul(a->Int.bitwiseXor(a->Int.shiftRightUnsigned(15)), a->Int.bitwiseOr(1))
  let c = b->Int.bitwiseXor(b + imul(b->Int.bitwiseXor(b->Int.shiftRightUnsigned(7)), b->Int.bitwiseOr(61)))
  let bits = c->Int.bitwiseXor(c->Int.shiftRightUnsigned(14))
  // `bits` is a signed 32-bit result; fold the sign bit back in to get the
  // unsigned value a `>>> 0` would produce.
  let unsigned = bits < 0 ? Int.toFloat(bits) +. 4294967296.0 : Int.toFloat(bits)
  unsigned /. 4294967296.0
}

/** Inclusive on both ends. */
let int = (r: t, ~min: int, ~max: int): int =>
  min + Int.fromFloat(float(r) *. Int.toFloat(max - min + 1))

let pick = (r: t, xs: array<'a>): option<'a> =>
  xs->Array.get(Int.fromFloat(float(r) *. Int.toFloat(xs->Array.length)))

let pickOr = (r: t, ~fallback: 'a, xs: array<'a>): 'a => pick(r, xs)->Option.getOr(fallback)

/**
 * Weighted sample without replacement.
 *
 * Used both for skewing which items are chosen (a few popular ones, a long
 * tail) and for shuffling — pass equal weights and a count equal to the input
 * length to get a deterministic permutation.
 */
let sampleWeighted = (r: t, entries: array<('a, float)>, ~count: int): array<'a> => {
  let pool = entries->Array.copy
  let chosen = []
  let remaining = count < pool->Array.length ? count : pool->Array.length
  for _ in 1 to remaining {
    let total = pool->Array.reduce(0.0, (sum, (_, w)) => sum +. w)
    let cursor = ref(float(r) *. total)
    let index = ref(pool->Array.length - 1)
    let found = ref(false)
    pool->Array.forEachWithIndex(((_, w), i) => {
      if !found.contents {
        cursor := cursor.contents -. w
        if cursor.contents <= 0.0 {
          index := i
          found := true
        }
      }
    })
    switch pool->Array.get(index.contents) {
    | Some((item, _)) =>
      chosen->Array.push(item)
      pool->Array.splice(~start=index.contents, ~remove=1, ~insert=[])
    | None => ()
    }
  }
  chosen
}

/**
 * Zipf-like weights over an already-ordered array: the first entry carries the
 * most weight and the tail decays smoothly. `exponent` controls how sharp the
 * head is — around 1.1 gives a clear leader with a long tail.
 */
let zipfWeights = (items: array<'a>, ~exponent: float): array<('a, float)> =>
  items->Array.mapWithIndex((item, rank) => (
    item,
    1.0 /. Math.pow(Int.toFloat(rank + 1), ~exp=exponent),
  ))
