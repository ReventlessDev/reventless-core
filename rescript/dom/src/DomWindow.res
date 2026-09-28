/** Bindings for the [`window`](https://developer.mozilla.org/docs/Web/API/Window) global:
    the viewport's size, listeners that hear an event wherever focus is, and the next
    frame.

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

/** Hears the event on its way down. A `scroll` does not bubble, so only a capturing
    listener on the window hears every scroll on the page, of any element. Removed with
    {!removeEventListenerCapture}. */
@val @scope("window")
external addEventListenerCapture: (string, 'event => unit, @as(json`true`) _) => unit =
  "addEventListener"

@val @scope("window")
external removeEventListenerCapture: (string, 'event => unit, @as(json`true`) _) => unit =
  "removeEventListener"

/** Runs the function before the next repaint, once the browser has laid the page out:
    where focusing an element just added takes effect. Returns the request's id. */
@val @scope("window")
external requestAnimationFrame: (float => unit) => int = "requestAnimationFrame"
