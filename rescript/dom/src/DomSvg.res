/** What SVG elements have beyond {!DomElement}. Make them with
    `DomDocument.createElementNS(DomSvg.namespace, name)`. */
let namespace = "http://www.w3.org/2000/svg"

/** An element's box in its own user units, before any transform. */
type box = {x: float, y: float, width: float, height: float}

@send
external getBBox: Dom.element => box = "getBBox"

/** The `viewBox` of an `<svg>` element, as the browser holds it. `baseVal` is null
    when the attribute is absent; the property itself is absent on an element
    that is not an `<svg>`. */
type animatedBox = {baseVal: Nullable.t<box>}

@get
external viewBox: Dom.element => Nullable.t<animatedBox> = "viewBox"

/** The nearest `<svg>` an element is drawn in, or null for the outermost one. */
@get
external ownerSVGElement: Dom.element => Nullable.t<Dom.element> = "ownerSVGElement"
