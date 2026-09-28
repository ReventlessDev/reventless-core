/** What every event can do, whatever record a listener reads it as.

    Each listener types its event itself (a pointer event's `clientX`, a key
    event's `key`), so these take any event. */
@send
external preventDefault: 'event => unit = "preventDefault"

@send
external stopPropagation: 'event => unit = "stopPropagation"

/** Whether an event of this name, dispatched on an element, reaches its ancestors. */
type init = {bubbles: bool}

type t

@new
external make: (string, init) => t = "Event"
