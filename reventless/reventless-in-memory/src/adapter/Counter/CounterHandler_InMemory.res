// In-memory counter handler — tracks counter values in module-level dicts.
// Deduplicates: a given (counterId, targetRef) pair is only counted once.
//
// Call CounterHandler_InMemory.reset() in beforeEach to isolate tests.

open ReventlessCore

let counterStore: ref<dict<int>> = ref(Dict.make())
let targetRefStore: ref<dict<bool>> = ref(Dict.make())

let make: Counter_Adapter.handlerMaker = (
  ~name as _,
  ~referencesName as _,
  ~referencesDb as _,
  ~countsName as _,
  ~countsDb as _,
  ~counterHandler as _,
  ~opts as _,
) => {
  addToCounterTarget: async ({Reventless.Counter.counterId, target, targetRef}) => {
    let refKey = counterId ++ ":" ++ targetRef
    switch targetRefStore.contents->Dict.get(refKey) {
    | Some(_) => () // Already counted this (counterId, targetRef) pair — skip
    | None =>
      targetRefStore.contents->Dict.set(refKey, true)
      let current = counterStore.contents->Dict.get(counterId)->Option.getOr(0)
      counterStore.contents->Dict.set(counterId, current + target)
    }
  },
}

// Returns the current count for a given counterId.
let getCount = counterId => counterStore.contents->Dict.get(counterId)->Option.getOr(0)

// Reset all counters — call in beforeEach for test isolation.
let reset = () => {
  counterStore.contents = Dict.make()
  targetRefStore.contents = Dict.make()
}
