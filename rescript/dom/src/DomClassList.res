/** Bindings for an element's
    [`classList`](https://developer.mozilla.org/docs/Web/API/Element/classList). */
@get
external classList: Dom.element => Dom.domTokenList = "classList"

@send
external add: (Dom.domTokenList, string) => unit = "add"

@send
external remove: (Dom.domTokenList, string) => unit = "remove"

@send
external contains: (Dom.domTokenList, string) => bool = "contains"

/** The classes, in the order the `class` attribute lists them, each once. */
@val
external toArray: Dom.domTokenList => array<string> = "Array.from"

/** Adds the class when `force` is true and removes it when false. */
@send
external toggle: (Dom.domTokenList, string, bool) => bool = "toggle"
