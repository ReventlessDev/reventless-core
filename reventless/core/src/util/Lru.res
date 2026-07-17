// Bounded in-process LRU cache — see Lru.resi for the contract.
//
// Recency is tracked via the backing JS Map's insertion order: `get`/`put`
// delete-then-set the touched key so it moves to the end, leaving the
// least-recently-used key as the first element of `Map.keys`. `put` evicts that
// first key once `size` exceeds `capacity`.

type t<'k, 'v> = {
  capacity: int,
  store: Map.t<'k, 'v>,
}

let make = (~capacity: int): t<'k, 'v> => {
  capacity,
  store: Map.make(),
}

let get = (cache: t<'k, 'v>, key: 'k): option<'v> =>
  switch cache.store->Map.get(key) {
  | Some(value) =>
    // Touch: re-insert so this key becomes most-recently-used.
    let _ = cache.store->Map.delete(key)
    cache.store->Map.set(key, value)
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
    cache.store->Map.set(key, value)
    if cache.store->Map.size > cache.capacity {
      // Evict the least-recently-used entry = oldest insertion = first key.
      switch cache.store->Map.keys->Array.fromIterator->Array.get(0) {
      | Some(oldest) => let _ = cache.store->Map.delete(oldest)
      | None => ()
      }
    }
  }

let invalidate = (cache: t<'k, 'v>, key: 'k): unit => {
  let _ = cache.store->Map.delete(key)
}

let clear = (cache: t<'k, 'v>): unit => cache.store->Map.clear

let size = (cache: t<'k, 'v>): int => cache.store->Map.size
