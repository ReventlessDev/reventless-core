/** Bindings for [`node:async_hooks`](https://nodejs.org/api/async_context.html): a value that
    follows one call and everything it awaits, and no other call running at the same time. */
type asyncLocalStorage<'a>

@module("node:async_hooks") @new
external makeAsyncLocalStorage: unit => asyncLocalStorage<'a> = "AsyncLocalStorage"

/** Runs the function with the value as the store, for it and for everything it awaits. */
@send
external run: (asyncLocalStorage<'a>, 'a, unit => 'b) => 'b = "run"

/** The store of the call this runs in; none outside a `run`. */
@send
external getStore: asyncLocalStorage<'a> => option<'a> = "getStore"
