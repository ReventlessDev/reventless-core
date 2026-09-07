// Reading a built plugin's declared structure.
//
// A plugin's generated definition module is a functor over the platform type
// that exposes `pluginStructure` as an ordinary value, and the local platform's
// `Make` takes no configuration — so applying one to the other is enough to hold
// a real structure. No deploy program, no database, no server, nothing left
// running.
//
// This lives in a companion `.mjs` because it is untyped reflection: `import` is
// syntax rather than a value, so a computed specifier cannot be bound as an
// external, and the value that comes back is shaped by the plugin rather than by
// anything this repository can name.
//
// The structure is handed back as plain JSON and read field by field on the
// ReScript side, rather than parsed through the published schema. A
// `pluginStructure` has two legitimate representations — an absent optional is
// `undefined` in memory and an explicit `null` on the wire — and the published
// schema describes the wire form, so validating an in-memory structure against
// it fails on every optional that happens to be empty.
import { existsSync } from "node:fs";
import { join } from "node:path";

const localPlatformPath = (pluginDir) =>
  join(
    pluginDir,
    "node_modules/@reventlessdev/reventless-local/src/Platform.res.mjs",
  );

const pluginEntryPath = (pluginDir) => join(pluginDir, "src/Plugin.res.mjs");

/**
 * @returns {Promise<{ok: true, structure: unknown} | {ok: false, error: string}>}
 */
export const loadPluginStructure = async (pluginDir) => {
  const entry = pluginEntryPath(pluginDir);
  const local = localPlatformPath(pluginDir);
  if (!existsSync(entry)) {
    return {
      ok: false,
      error: `no compiled plugin at ${entry} — build the plugin first`,
    };
  }
  if (!existsSync(local)) {
    return {
      ok: false,
      error: `no local platform installed at ${local}`,
    };
  }
  try {
    const localMod = await import(local);
    const pluginMod = await import(entry);
    const structure = pluginMod.Make(localMod.Make()).pluginStructure;
    // A structure whose component arrays are absent came from a release this
    // reader cannot understand. Saying so beats reporting a model that is
    // quietly half-empty.
    const present = ["readModels", "stateViewSlices", "stateChangeSlices", "aggregates"].every(
      (k) => Array.isArray(structure?.[k]),
    );
    return present
      ? { ok: true, structure }
      : { ok: false, error: "the plugin structure declares no component arrays" };
  } catch (e) {
    const message = e && (e.message || e.RE_EXN_ID) ? String(e.message || e.RE_EXN_ID) : "unknown error";
    return { ok: false, error: `reading the plugin structure: ${message}` };
  }
};
