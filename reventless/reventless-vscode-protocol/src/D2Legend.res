// Shared legend-entry shape + swatch-building constructors for the D2 diagram
// legends. The Event Graph (DomainGraphD2 here) and the extension's Context Map
// downstream both render the same legend-panel shape, and each previously carried
// its own identical `legendEntry` type + entry builder; the per-view
// `presentKeys`/`applyLegendFilter` stay with each view since their logic differs.

@genType
type legendEntry = {
  key: string,
  kindType: string, // "node" | "edge"
  label: string,
  description: string,
  swatch: string,
  toggleable: bool,
}

// A node legend row. `key` is the node kind the host toggles on; `class_` is the D2
// class whose palette colour becomes the swatch.
let nodeEntry = (~class_, ~toggleable=true, key, label, description): legendEntry => {
  key,
  kindType: "node",
  label,
  description,
  swatch: D2Classes.swatchColor(class_),
  toggleable,
}

// An edge legend row. `cls` is both the toggle key and the swatch's D2 class.
let edgeEntry = (~toggleable=true, cls, label, description): legendEntry => {
  key: cls,
  kindType: "edge",
  label,
  description,
  swatch: D2Classes.swatchColor(cls),
  toggleable,
}
