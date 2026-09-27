# Plan (Backlog): a view's failing scenario points at `project`

**Status:** Backlog (not started)

`Hint.res` answers a `StateMismatch` with locus `<Slice>.evolve` and "evolve() produced a
different state than expected". That is right for an aggregate or a state-change slice. A
state view slice's scenario fails the same way, and a view has no `evolve`: its fold is
`project`, in `<Slice>_Projection.res`, so the hint sends the reader to a function that does
not exist.

**Change:** the hint knows which harness produced the mismatch. `Projection_GWT` reports locus
`<Slice>.project` and "project() filed a different row than expected. Check the arm for the
event and the key it sets."

**Verify:** a view scenario whose row differs prints the `project` hint; a behavior's still
prints the `evolve` one.
