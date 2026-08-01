// Loader for the frozen plugin-lifecycle payload corpus. See ./README.md.
//
// Reads the fixtures off disk rather than importing them: a JSON `import` needs an
// import attribute, and the file list would then have to be maintained twice.
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const dir = dirname(fileURLToPath(import.meta.url));

// Sorted so the corpus reads in shape-generation order (filenames are date-prefixed)
// and a failure names the same entry on every machine.
export const entries = readdirSync(dir)
  .filter((f) => f.endsWith(".json"))
  .sort()
  .map((name) => {
    const { event, data } = JSON.parse(readFileSync(join(dir, name), "utf8"));
    return { name, event, data };
  });
