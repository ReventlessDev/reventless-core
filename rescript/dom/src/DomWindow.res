/** Bindings for the [`window`](https://developer.mozilla.org/docs/Web/API/Window) global:
    the viewport's size, and listeners that hear an event wherever focus is.

    The event type is the caller's: each listener names the record it reads
    (a key event's `key`, a pointer event's `clientX`), and the same function must
    be passed to {!removeEventListener} as was added. */
@val @scope("window")
external innerWidth: float = "innerWidth"

@val @scope("window")
external innerHeight: float = "innerHeight"

@val @scope("window")
external addEventListener: (string, 'event => unit) => unit = "addEventListener"

@val @scope("window")
external removeEventListener: (string, 'event => unit) => unit = "removeEventListener"
