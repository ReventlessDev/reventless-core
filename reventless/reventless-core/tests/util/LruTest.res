open JestGlobals

describe("Lru:", () => {
  describe("get / put", () => {
    testSync("get on an empty cache misses", () => {
      let cache = Lru.make(~capacity=2)
      expect(cache->Lru.get("a"))->toEqual(None)
    })

    testSync("put then get returns the stored value", () => {
      let cache = Lru.make(~capacity=2)
      cache->Lru.put("a", 1)
      expect(cache->Lru.get("a"))->toEqual(Some(1))
    })

    testSync("put on an existing key overwrites", () => {
      let cache = Lru.make(~capacity=2)
      cache->Lru.put("a", 1)
      cache->Lru.put("a", 2)
      expect((cache->Lru.get("a"), cache->Lru.size))->toEqual((Some(2), 1))
    })

    testSync("invalidate removes a key", () => {
      let cache = Lru.make(~capacity=2)
      cache->Lru.put("a", 1)
      cache->Lru.invalidate("a")
      expect((cache->Lru.get("a"), cache->Lru.size))->toEqual((None, 0))
    })
  })

  describe("eviction", () => {
    testSync("evicts the least-recently-used entry past capacity", () => {
      let cache = Lru.make(~capacity=2)
      cache->Lru.put("a", 1)
      cache->Lru.put("b", 2)
      cache->Lru.put("c", 3) // evicts "a" (oldest)
      expect((cache->Lru.get("a"), cache->Lru.get("b"), cache->Lru.get("c"), cache->Lru.size))->toEqual((
        None,
        Some(2),
        Some(3),
        2,
      ))
    })

    testSync("get refreshes recency so a touched key survives eviction", () => {
      let cache = Lru.make(~capacity=2)
      cache->Lru.put("a", 1)
      cache->Lru.put("b", 2)
      let _ = cache->Lru.get("a") // "a" is now most-recently-used
      cache->Lru.put("c", 3) // evicts "b", not "a"
      expect((cache->Lru.get("a"), cache->Lru.get("b"), cache->Lru.get("c")))->toEqual((
        Some(1),
        None,
        Some(3),
      ))
    })

    testSync("101 distinct keys against capacity 100 keeps exactly 100", () => {
      let cache = Lru.make(~capacity=100)
      // 101 distinct keys: 0..100 inclusive.
      Array.fromInitializer(~length=101, i => i)->Array.forEach(i => cache->Lru.put(i, i))
      expect((cache->Lru.size, cache->Lru.get(0), cache->Lru.get(100)))->toEqual((100, None, Some(100)))
    })
  })

  describe("disabled cache (capacity <= 0)", () => {
    testSync("never stores", () => {
      let cache = Lru.make(~capacity=0)
      cache->Lru.put("a", 1)
      expect((cache->Lru.get("a"), cache->Lru.size))->toEqual((None, 0))
    })
  })
})
