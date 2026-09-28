/** Bindings for the [`document`](https://developer.mozilla.org/docs/Web/API/Document)
    global: making nodes, finding them, and listening to the whole page.

    An SVG element must be made with {!createElementNS} and the SVG namespace
    ({!DomSvg.namespace}); `createElement("rect")` makes an HTML element of that
    name, which a browser does not draw. */
@val @scope("document")
external createElement: string => Dom.element = "createElement"

@val @scope("document")
external createElementNS: (string, string) => Dom.element = "createElementNS"

@val @scope("document")
external createTextNode: string => Dom.element = "createTextNode"

@val @scope("document")
external createDocumentFragment: unit => Dom.element = "createDocumentFragment"

@val @scope("document")
external body: Dom.element = "body"

/** The `<html>` element: the viewport's size without the scrollbar, and the custom
    properties every rule can read. */
@val @scope("document")
external documentElement: Dom.element = "documentElement"

@val @scope("document")
external getElementById: string => Nullable.t<Dom.element> = "getElementById"

/** The topmost element at a point in the viewport, or null outside it. */
@val @scope("document")
external elementFromPoint: (float, float) => Nullable.t<Dom.element> = "elementFromPoint"

@val @scope("document")
external querySelector: string => Nullable.t<Dom.element> = "querySelector"

@val @scope("document")
external querySelectorAll: string => Dom.nodeList = "querySelectorAll"

// ── Listening ────────────────────────────────────────────────────────────────

/** The event type is the caller's (see {!DomWindow}). An event that bubbles reaches the
    document from any element; one that does not (`focus`) has a bubbling twin
    (`focusin`). */
@val @scope("document")
external addEventListener: (string, 'event => unit) => unit = "addEventListener"

@val @scope("document")
external removeEventListener: (string, 'event => unit) => unit = "removeEventListener"

/** Hears the event on its way down, before the element it happens on does: what a popup
    listens with to close on a press outside it, whatever the pressed element does. Removed
    with {!removeEventListenerCapture}, which a listener added without capture is not. */
@val @scope("document")
external addEventListenerCapture: (string, 'event => unit, @as(json`true`) _) => unit =
  "addEventListener"

@val @scope("document")
external removeEventListenerCapture: (string, 'event => unit, @as(json`true`) _) => unit =
  "removeEventListener"
