// Per-node SVG shapes for extension points (a two-sided socket) and extensions (a plug:
// point on the left, flat right) — so the two read as interlocking. The label is baked
// into the SVG as centred `<text>` so it renders INSIDE the shape (an `image` node's d2
// label would render outside), which is why the SVG is built per node rather than as one
// shared constant. The geometry + text sizing live here (structural); the colours come
// from the generated `D2Classes` so they stay single-sourced from the canonical palette.
//
// `toD2` uses the returned width/height for the d2 image node and gives the node an empty
// d2 label (the visible text is the SVG `<text>`). No vscode dependency — headless.

type t = {uri: string, width: int, height: int}

// Environment-agnostic UTF-8 → base64: Node hosts (extension host, tests) have `Buffer`;
// browser hosts (WASM d2 rasterization) get `TextEncoder` + `btoa`. Labels are short, so
// the spread-into-fromCharCode path never approaches the argument limit.
let base64: string => string = %raw(`s =>
  typeof Buffer !== "undefined"
    ? Buffer.from(s, "utf8").toString("base64")
    : btoa(String.fromCharCode(...new TextEncoder().encode(s)))`)

// Escape the label for XML text content (labels carry `.`/`:`; guard the rest too).
let xmlEscape = (s: string): string =>
  s
  ->String.replaceRegExp(%re("/&/g"), "&amp;")
  ->String.replaceRegExp(%re("/</g"), "&lt;")
  ->String.replaceRegExp(%re("/>/g"), "&gt;")
  ->String.replaceRegExp(%re("/\"/g"), "&quot;")

let fontAttrs = `font-family="-apple-system,Segoe UI,Roboto,sans-serif" font-weight="600" font-size="16"`

let height = 70

// Rough advance width of the label at 16px (dotted identifiers); the node grows to fit.
let textWidth = (label: string): int => Int.fromFloat(Float.fromInt(String.length(label)) *. 8.6)

let dataUri = (svg: string): string => "data:image/svg+xml;base64," ++ base64(svg)

// Two-sided socket: a bowtie with a full-height notch on each side. Body grows with the
// label; the notch depth (16) matches the extension's point so they interlock.
let extensionPointIcon = (label: string): t => {
  let w = textWidth(label) + 96
  let svg =
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${Int.toString(w)} ${Int.toString(height)}">` ++
    `<path d="M12 10 L${Int.toString(w - 12)} 10 L${Int.toString(w - 28)} 35 L${Int.toString(
        w - 12,
      )} 60 L12 60 L28 35 Z" ` ++
    `fill="${D2Classes.extensionPointFill}" stroke="${D2Classes.extensionPointStroke}" stroke-width="3" stroke-linejoin="round"/>` ++
    `<text x="${Int.toString(w / 2)}" y="35" text-anchor="middle" dominant-baseline="central" ` ++
    `fill="${D2Classes.extensionPointFontColor}" ${fontAttrs}>${xmlEscape(label)}</text></svg>`
  {uri: dataUri(svg), width: w, height}
}

// Plug: full-height point on the left, flat right. Body (and label) grow with the label.
let extensionIcon = (label: string): t => {
  let w = textWidth(label) + 80
  let svg =
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${Int.toString(w)} ${Int.toString(height)}">` ++
    `<path d="M26 10 L${Int.toString(w - 10)} 10 L${Int.toString(w - 10)} 60 L26 60 L10 35 Z" ` ++
    `fill="${D2Classes.extensionFill}" stroke="${D2Classes.extensionStroke}" stroke-width="3" stroke-linejoin="round"/>` ++
    `<text x="${Int.toString((w + 16) / 2)}" y="35" text-anchor="middle" dominant-baseline="central" ` ++
    `fill="${D2Classes.extensionFontColor}" ${fontAttrs}>${xmlEscape(label)}</text></svg>`
  {uri: dataUri(svg), width: w, height}
}
