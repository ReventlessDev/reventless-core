#!/usr/bin/env node
// Fails when a package's `i18n/en.json` is not the English its server messages are written in.
//
// A server message is a key and its English, in code beside the code that sends it, so a
// deployment with no catalogue still sends something readable. A translator works from the
// package's `i18n/en.json`, which a deployment lists among its catalogue sources; this keeps
// the file the same as the code. Run after a build: it reads the compiled modules.
//
// Usage: node scripts/check-server-catalogues.mjs [--update]

import { readFileSync, writeFileSync, mkdirSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")

// Each package that sends: the compiled module holding its messages, and the file it ships.
const packages = [
  {
    module:
      "reventless/registration/src/Registration/OutboundTranslation/SendRegistrationChallenge_Translation.res.mjs",
    messages: (m) => m.Messages.all,
    file: "reventless/registration/i18n/en.json",
  },
]

const update = process.argv.includes("--update")

// Written as a merged catalogue is: keys sorted, two-space indent, a final newline.
const catalogueText = (messages) =>
  JSON.stringify(
    Object.fromEntries(
      messages.map((m) => [m.key, m.source]).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)),
    ),
    null,
    2,
  ) + "\n"

let stale = 0
for (const pkg of packages) {
  const module = await import(pathToFileURL(join(root, pkg.module)).href)
  const expected = catalogueText(pkg.messages(module))
  const path = join(root, pkg.file)
  let actual = null
  try {
    actual = readFileSync(path, "utf8")
  } catch {}
  if (actual === expected) {
    console.log(`ok     ${pkg.file}`)
  } else if (update) {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, expected)
    console.log(`wrote  ${pkg.file}`)
  } else {
    console.log(`stale  ${pkg.file}`)
    stale++
  }
}

if (stale > 0) {
  console.log("\nThe English of a package's server messages changed. Run")
  console.log("  pnpm run check:server-catalogues:update")
  console.log("and commit the catalogue with the change that moved it.")
  process.exit(1)
}
