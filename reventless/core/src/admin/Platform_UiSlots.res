// Where a deployment's slot module goes, and what the shell is told to fetch.
//
// Stated once, in core, for the reason `Platform_BakedManifest.defaultKey`
// gives: four places have to agree on this string — the AWS `BucketObject` key,
// the `uiSlotsUrl` the AWS deploy writes into `config.json`, the file the local
// platform serves out of the host-shell `dist/`, and the `uiSlotsUrl` that
// platform overlays. A platform that spelled it differently from the one that
// wrote the config key would put the module where nothing imports it, and the
// symptom is a surface that draws its own regions — indistinguishable from a
// deployment that declared no slots at all.
//
// Both platforms write the module beside `config.json` at what is also the
// shell's URL root, so the file name and the path the browser asks for are one
// string.

let fileName = "ui-slots.js"

/** The `config.json` key naming the module, as `SlotModules.load` reads it. */
let configKey = "uiSlotsUrl"

let url = "/" ++ fileName
