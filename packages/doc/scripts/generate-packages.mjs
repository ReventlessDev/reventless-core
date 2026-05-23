// Generates src/data/packages.json from the monorepo's package.json files so
// the Packages reference page can never drift from the actual workspace.
// Runs automatically before `start` and `build` (see package.json scripts).
import {readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..', '..', '..');
const outFile = resolve(here, '..', 'src', 'data', 'packages.json');

// Workspace root folder -> reference-page category. Order here is render order.
const CATEGORIES = [
  {
    dir: 'reventless',
    title: 'Framework',
    description: 'The Reventless framework and its extension packages.',
  },
  {
    dir: 'rescript',
    title: 'ReScript Bindings',
    description: 'ReScript bindings for the JS/npm libraries used across the framework.',
  },
  {
    dir: 'packages',
    title: 'Tooling',
    description: 'Build tooling, the PPX, and editor integration.',
  },
];

function readPackages(dir) {
  const root = join(repoRoot, dir);
  if (!existsSync(root)) return [];
  return readdirSync(root, {withFileTypes: true})
    .filter((e) => e.isDirectory())
    .map((e) => join(root, e.name, 'package.json'))
    .filter((p) => existsSync(p))
    .map((p) => JSON.parse(readFileSync(p, 'utf8')))
    .filter((j) => j.name && j.name !== 'doc') // the docs site documents itself elsewhere
    .map((j) => ({
      name: j.name,
      description: j.description || '',
      private: Boolean(j.private),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

const categories = CATEGORIES.map((c) => ({
  title: c.title,
  description: c.description,
  packages: readPackages(c.dir),
})).filter((c) => c.packages.length > 0);

const total = categories.reduce((n, c) => n + c.packages.length, 0);

mkdirSync(dirname(outFile), {recursive: true});
writeFileSync(outFile, JSON.stringify({categories}, null, 2) + '\n');

console.log(`generate-packages: wrote ${total} packages to src/data/packages.json`);
