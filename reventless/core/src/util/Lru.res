// Bounded in-process LRU cache — see Lru.resi for the contract.
//
// Recency is tracked via the backing JS Map's insertion order: `get`/`put`
// delete-then-set the touched key so it moves to the end, leaving the
// least-recently-used key as the first element of `Map.keys`. `put` evicts that
// first key once `size` exceeds `capacity`.

// An entry also carries when it stops being served: decoded state holds personal
// values in the clear, and an erased person's must leave a warm container within a
// bound the erasure promise can name, not whenever the entry happens to be evicted.

type t<'k, 'v> = {
  capacity: int,
  ttlMs: option<float>,
  now: unit => float,
  store: Map.t<'k, ('v, float)>,
}

@val external env: dict<string> = "process.env"

/** The time limit a cache of decoded state takes unless it says otherwise: five
    minutes, or `REVENTLESS_DECODED_CACHE_TTL_SECONDS`. */
let decodedStateTtlMs = (): float =>
  env
  ->Dict.get("REVENTLESS_DECODED_CACHE_TTL_SECONDS")
  ->Option.flatMap(Float.fromString)
  ->Option.filter(s => s > 0.)
  ->Option.getOr(300.) *. 1000.

let make = (~capacity: int, ~ttlMs: option<float>=?, ~now: unit => float=Date.now): t<'k, 'v> => {
  capacity,
  ttlMs,
  now,
  store: Map.make(),
}

let get = (cache: t<'k, 'v>, key: 'k): option<'v> =>
  switch cache.store->Map.get(key) {
  | Some((_, expiresAt)) if cache.now() >= expiresAt =>
    let _ = cache.store->Map.delete(key)
    None
  | Some((value, expiresAt)) =>
    // Touch: re-insert so this key becomes most-recently-used. The time limit runs
    // from the put, not from the last read, so a hot key still expires.
    let _ = cache.store->Map.delete(key)
    cache.store->Map.set(key, (value, expiresAt))
    Some(value)
  | None => None
  }

let put = (cache: t<'k, 'v>, key: 'k, value: 'v): unit =>
  if cache.capacity <= 0 {
    // Disabled cache — nothing to store.
    ()
  } else {
    // Delete first so an update also moves the key to most-recently-used.
    let _ = cache.store->Map.delete(key)
    let expiresAt = switch cache.ttlMs {
    | Some(ttl) => cache.now() +. ttl
    | None => Float.Constants.positiveInfinity
    }
    cache.store->Map.set(key, (value, expiresAt))
    if cache.store->Map.size > cache.capacity {
      // Evict the least-recently-used entry = oldest insertion = first key.
      switch cache.store->Map.keys->Array.fromIterator->Array.get(0) {
      | Some(oldest) =>
        let _ = cache.store->Map.delete(oldest)
      | None => ()
      }
    }
  }

let invalidate = (cache: t<'k, 'v>, key: 'k): unit => {
  let _ = cache.store->Map.delete(key)
}

let clear = (cache: t<'k, 'v>): unit => cache.store->Map.clear

let size = (cache: t<'k, 'v>): int => cache.store->Map.size
