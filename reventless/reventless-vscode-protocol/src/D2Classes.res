// GENERATED FILE — do not edit by hand.
// The semantic D2 class block + single-sourced extension-point/extension shape colours,
// shared by every D2 graph view over the protocol model. Source of truth: shared classes +
// colours come from packages/doc/d2/reventless.d2 (this repo); tooling-only classes
// (boundary/box/chapter/slices) live in scripts/d2-classes-gen.mjs; the socket/plug
// geometry lives in src/D2Shapes.res. Regenerate with `pnpm sync:d2-styles`; verified by
// tests/D2ClassesGenTest.res.
let classes = `classes: {
  command: { style: { fill: "#DBEAFE"; stroke: "#2563EB"; font-color: "#1E3A8A"; border-radius: 20 } }
  "msg-event": { style: { fill: "#FED7AA"; stroke: "#EA580C"; font-color: "#7C2D12"; border-radius: 20 } }
  aggregate: { style: { fill: "#FEF9C3"; stroke: "#CA8A04"; font-color: "#713F12"; border-radius: 6 } }
  "state-change-slice": { style: { fill: "#FEF3C7"; stroke: "#D97706"; font-color: "#92400E"; border-radius: 4 } }
  "read-model": { style: { fill: "#DCFCE7"; stroke: "#16A34A"; font-color: "#14532D"; border-radius: 6 } }
  "state-view-slice": { style: { fill: "#BBF7D0"; stroke: "#15803D"; font-color: "#14532D"; border-radius: 4 } }
  "automation-slice": { style: { fill: "#E9D5FF"; stroke: "#9333EA"; font-color: "#581C87"; border-radius: 4 } }
  "side-effect": { style: { fill: "#FFF1F2"; stroke: "#E11D48"; font-color: "#881337"; border-radius: 6 } }
  "extension-point": { shape: hexagon; style: { fill: "#7DD3FC"; stroke: "#0284C7"; font-color: "#0C4A6E" } }
  extension: { shape: hexagon; style: { fill: "#BAE6FD"; stroke: "#0284C7"; font-color: "#0C4A6E" } }
  "external-system": { style: { fill: "#FDA4AF"; stroke: "#E11D48"; font-color: "#881337"; border-radius: 6; stroke-dash: 4 } }
  boundary: { style: { fill: "#BAE6FD"; stroke: "#0284C7"; font-color: "#0C4A6E"; border-radius: 6 } }
  box: { style: { fill: "#F3F4F6"; stroke: "#6B7280"; font-color: "#1F2937"; border-radius: 6 } }
  chapter: { style: { fill: "#E0E7FF"; stroke: "#4F46E5"; font-color: "#3730A3"; border-radius: 8; stroke-dash: 3 } }
  "write-side": { style: { fill: "#FEFCE8"; stroke: "#CA8A04"; font-color: "#713F12"; border-radius: 10 } }
  "read-side": { style: { fill: "#ECFDF5"; stroke: "#0D9488"; font-color: "#134E4A"; border-radius: 10 } }
  "slice-inprogress": { style: { fill: "#EFF6FF"; stroke: "#2563EB"; font-color: "#1E3A8A"; border-radius: 10; stroke-width: 2 } }
  "slice-done": { style: { fill: "#DCFCE7"; stroke: "#16A34A"; font-color: "#14532D"; border-radius: 10 } }
  "dcb-read": { style: { stroke: "#7C3AED"; font-color: "#7C3AED"; stroke-dash: 2 } }
  "dcb-read-xp": { style: { stroke: "#C026D3"; font-color: "#C026D3"; stroke-dash: 4 } }
  "command-flow": { style: { stroke: "#2563EB"; font-color: "#2563EB" } }
  "event-flow": { style: { stroke: "#EA580C"; font-color: "#EA580C" } }
  "projection-flow": { style: { stroke: "#16A34A"; font-color: "#16A34A" } }
  "cross-plugin": { style: { stroke: "#0D9488"; font-color: "#0D9488"; stroke-dash: 4 } }
}`

// Single-sourced colours for the custom extension-point (socket) / extension (plug)
// shapes — consumed by D2Shapes.res, which bakes the label into the SVG per node.
let extensionPointFill = "#7DD3FC"
let extensionPointStroke = "#0284C7"
let extensionPointFontColor = "#0C4A6E"
let extensionFill = "#BAE6FD"
let extensionStroke = "#0284C7"
let extensionFontColor = "#0C4A6E"

// Per-class swatch colour for the Event Graph legend (see buildSwatchColors).
let swatchColor = (cls: string): string =>
  switch cls {
  | "command" => "#2563EB"
  | "msg-event" => "#EA580C"
  | "aggregate" => "#CA8A04"
  | "state-change-slice" => "#D97706"
  | "read-model" => "#16A34A"
  | "state-view-slice" => "#15803D"
  | "automation-slice" => "#9333EA"
  | "side-effect" => "#E11D48"
  | "extension-point" => "#0284C7"
  | "extension" => "#0284C7"
  | "external-system" => "#E11D48"
  | "boundary" => "#0284C7"
  | "box" => "#6B7280"
  | "chapter" => "#4F46E5"
  | "write-side" => "#CA8A04"
  | "read-side" => "#0D9488"
  | "slice-inprogress" => "#2563EB"
  | "slice-done" => "#16A34A"
  | "dcb-read" => "#7C3AED"
  | "dcb-read-xp" => "#C026D3"
  | "command-flow" => "#2563EB"
  | "event-flow" => "#EA580C"
  | "projection-flow" => "#16A34A"
  | "cross-plugin" => "#0D9488"
  | _ => "#6B7280"
  }
