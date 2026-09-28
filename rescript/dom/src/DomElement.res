/** Bindings for an [`Element`](https://developer.mozilla.org/docs/Web/API/Element):
    its attributes and content, where it sits in the tree, finding others from
    it, its size on screen, and listening to it.

    Everything takes ReScript's own `Dom.element`, so these work on an HTML
    element, an SVG element and a text node alike, as the browser's methods do. */
@send
external // ── Attributes and content ───────────────────────────────────────────────────

setAttribute: (Dom.element, string, string) => unit = "setAttribute"

@send
external getAttribute: (Dom.element, string) => Nullable.t<string> = "getAttribute"

@send
external removeAttribute: (Dom.element, string) => unit = "removeAttribute"

@send
external hasAttribute: (Dom.element, string) => bool = "hasAttribute"

@set
external setId: (Dom.element, string) => unit = "id"

@get
external id: Dom.element => string = "id"

@set
external setClassName: (Dom.element, string) => unit = "className"

@set
external setTextContent: (Dom.element, string) => unit = "textContent"

@get
external textContent: Dom.element => Nullable.t<string> = "textContent"

@set
external setTitle: (Dom.element, string) => unit = "title"

/** The `data-*` attributes, keyed without the prefix and in camelCase
    (`data-slice-id` is `sliceId`). Setting a key writes the attribute. */
@get
external dataset: Dom.element => dict<string> = "dataset"

/** Upper case for an HTML element (`"DIV"`), as written for an SVG one (`"rect"`). */
@get
external tagName: Dom.element => string = "tagName"

@get
external isContentEditable: Dom.element => bool = "isContentEditable"

// ── Place in the tree ────────────────────────────────────────────────────────

/** The parent node, which for the outermost element is the document itself: a
    node with none of the methods here. A walk up the tree that calls them on
    each step wants {!parentElement}. */
@get
external parentNode: Dom.element => Nullable.t<Dom.element> = "parentNode"

/** The parent element, or null above the outermost one. Walking up with this
    never reaches the document, so every step is an element with a class list
    and attributes. */
@get
external parentElement: Dom.element => Nullable.t<Dom.element> = "parentElement"

@get
external firstChild: Dom.element => Nullable.t<Dom.element> = "firstChild"

@get
external nextSibling: Dom.element => Nullable.t<Dom.element> = "nextSibling"

@send
external appendChild: (Dom.element, Dom.element) => unit = "appendChild"

/** Appends text as a text node; {!appendChild} appends an element. */
@send
external appendText: (Dom.element, string) => unit = "append"

@send
external insertBefore: (Dom.element, Dom.element, Nullable.t<Dom.element>) => unit = "insertBefore"

@send
external replaceWith: (Dom.element, Dom.element) => unit = "replaceWith"

@send
external remove: Dom.element => unit = "remove"

/** Whether the second is the first or inside it. */
@send
external contains: (Dom.element, Dom.element) => bool = "contains"

// ── Finding others from here ─────────────────────────────────────────────────

@send
external querySelector: (Dom.element, string) => Nullable.t<Dom.element> = "querySelector"

@send
external querySelectorAll: (Dom.element, string) => Dom.nodeList = "querySelectorAll"

/** This element or its nearest ancestor that matches the selector. */
@send
external closest: (Dom.element, string) => Nullable.t<Dom.element> = "closest"

// ── Size on screen ───────────────────────────────────────────────────────────

/** The box in viewport pixels. */
type rect = {left: float, top: float, right: float, bottom: float, width: float, height: float}

@send
external getBoundingClientRect: Dom.element => rect = "getBoundingClientRect"

/** Inner size, padding included, border and scrollbar not. */
@get
external clientWidth: Dom.element => float = "clientWidth"

@get
external clientHeight: Dom.element => float = "clientHeight"

/** Laid-out size, border included. */
@get
external offsetWidth: Dom.element => float = "offsetWidth"

@get
external offsetHeight: Dom.element => float = "offsetHeight"

// ── Listening ────────────────────────────────────────────────────────────────

/** The event type is the caller's (see {!DomWindow}), and the same function must
    be passed to {!removeEventListener} as was added. */
@send
external addEventListener: (Dom.element, string, 'event => unit) => unit = "addEventListener"

/** `passive: true` promises the listener will not call `preventDefault`, which
    lets a browser scroll without waiting for it. A listener that does prevent the
    default (a wheel that zooms instead of scrolling) must pass `passive: false`. */
type listenerOptions = {passive: bool}

@send
external addEventListenerWith: (Dom.element, string, 'event => unit, listenerOptions) => unit =
  "addEventListener"

@send
external removeEventListener: (Dom.element, string, 'event => unit) => unit = "removeEventListener"

@send
external dispatchEvent: (Dom.element, DomEvent.t) => bool = "dispatchEvent"

/** Sends the pointer's later events to this element until it is released, even
    once the pointer leaves it: what keeps a drag going past the element's edge. */
@send
external setPointerCapture: (Dom.element, int) => unit = "setPointerCapture"
