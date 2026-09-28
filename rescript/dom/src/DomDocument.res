/** Bindings for the [`document`](https://developer.mozilla.org/docs/Web/API/Document)
    global: making nodes, and finding one by position or id.

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

@val @scope("document")
external getElementById: string => Nullable.t<Dom.element> = "getElementById"

/** The topmost element at a point in the viewport, or null outside it. */
@val @scope("document")
external elementFromPoint: (float, float) => Nullable.t<Dom.element> = "elementFromPoint"
