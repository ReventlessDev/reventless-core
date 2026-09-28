# @reventlessdev/rescript-dom

ReScript bindings for the browser DOM: making and finding elements, their
attributes, content and size, SVG, inline styles, class lists, form fields and
events.

## Where the line is

This package is **browser-only**: it binds `document`, `window` and the element
API, which Node does not have. The web globals that exist in both a browser and
Node (`fetch`, `WebSocket`, timers, base64) are `rescript-web`'s, and imported
Node modules are `rescript-node`'s.

Everything is typed over ReScript's own `Dom.element`, `Dom.nodeList` and
`Dom.domTokenList`, so code that already holds those keeps its types.

## Design note

The surface is driven by call sites, not by the specification: it binds what
the graph webviews and the creation form actually call, and omits the rest.
Add to it when a consumer appears, not in anticipation of one.

Two choices follow from that:

- **Style setters are one per property** (`DomStyle.setDisplay`), so a misspelt
  property is a compile error rather than a style that does nothing.
  `DomStyle.setProperty` covers the rest, such as custom properties.
- **Listeners take the caller's event type.** A pointer listener reads
  `clientX`, a key listener `key`; each names the record it reads, and the
  functions in `DomEvent` accept any of them.

## Usage

```rescript
let chip = DomDocument.createElementNS(DomSvg.namespace, "rect")
chip->DomElement.setAttribute("rx", "4")
svg->DomElement.appendChild(chip)

let onKey = (e: {"key": string}) => if e["key"] == "Escape" { close() }
DomWindow.addEventListener("keydown", onKey)
```
