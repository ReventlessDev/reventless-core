// In-memory counter handler — no-op for testing.
// The addToCounterTarget is a no-op since we don't track counter targets in tests.

open Reventless

let make: Counter_Adapter.handlerMaker = (
  ~name as _,
  ~referencesName as _,
  ~referencesDb as _,
  ~countsName as _,
  ~countsDb as _,
  ~counterHandler as _,
  ~opts as _,
) => {
  {addToCounterTarget: async _counterTargetRef => ()}
}
