// Reflection over sury's internal schema shape, kept in JS because it is untyped
// by nature — walking `items` / `additionalItems` / `anyOf` off a schema object.
// Read by PluginDefinitionRequiredScalarsTest.res.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const GOLDEN = "pluginDefinitionRequiredScalars.txt";

const isSchema = (x) => x && typeof x === "object" && typeof x.type === "string";
const SCALARS = ["string", "number", "boolean", "bigint"];

/**
 * Every field reachable from `schema` whose type is a bare required scalar —
 * the one shape `fillMissingDefaults` cannot supply a schema-derived value for,
 * so adding one forces a fabricated value into every older stored message.
 *
 * Not reported, because each of these IS healable from the schema alone:
 *   - `T | null` unions      → null
 *   - const / enum unions    → the literal
 *   - arrays                 → []
 *   - objects                → {} filled recursively
 *
 * Reported even under a nullable parent: when an old payload happens to carry
 * the parent, a scalar added inside it still has to be invented. That is exactly
 * how `requiredStoreDeclarations[].annotation` froze a plugin.
 */
export const collect = (schema) => {
  const out = [];
  const seen = new Set();
  const walk = (s, path) => {
    if (!isSchema(s) || seen.has(s)) return;
    switch (s.type) {
      case "object": {
        seen.add(s);
        for (const it of s.items || []) walk(it.schema, `${path}.${it.location}`);
        seen.delete(s);
        return;
      }
      case "array": {
        if (isSchema(s.additionalItems)) walk(s.additionalItems, `${path}[]`);
        return;
      }
      case "union": {
        // A union of literals is an enum: absent heals to the first variant.
        if ((s.anyOf || []).every((m) => m.const !== undefined || m.type === "null")) return;
        const nullable = !!(s.has && s.has.null);
        for (const m of s.anyOf || []) {
          if (m.type === "null") continue;
          // A SCALAR arm of a `T | null` union heals to null — that is the
          // `js_nullable` encoding the rule asks authors to reach for, so
          // reporting it would flag the recommended shape.
          if (nullable && SCALARS.includes(m.type)) continue;
          // Object and array arms are still walked, nullable or not: when an old
          // payload happens to carry the parent, a scalar added inside it must
          // still be invented. `requiredStoreDeclarations[].annotation` — a
          // required string inside a nullable array — is exactly that case.
          walk(m, path);
        }
        return;
      }
      default: {
        if (s.const !== undefined) return;
        if (SCALARS.includes(s.type)) out.push(`${path}: ${s.type}`);
      }
    }
  };
  walk(schema, "");
  return out.sort();
};

/** The checked-in list. See the header of that file before changing it. */
export const golden = () =>
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), GOLDEN), "utf8")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith("#"));
