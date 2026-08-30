#!/usr/bin/env node
// Prove each trait package's boundary is real: pack it, install the tarball —
// not the workspace link — beside a copy of its specimen host, and build the
// host against it. Workspace resolution hides exactly the defects this catches:
// a `files` allowlist that omits what the consumer compiles, a tarball that
// needs `lib/`, a `.cmi` skew. A scaffold-shaped trait has no linked code to
// fail at link time, so this is the only check that says the package installs.
//
// Usage: node scripts/check-trait-pack.mjs   (exit 1 on failure)

import { execFileSync } from "node:child_process"
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")

// trait dir → the host that binds it. Add a row per trait.
const specimens = {
  "traits/address-geocoding": "examples/online-shop-hybrid/ordering",
  "traits/file-attachment": "examples/online-shop-hybrid/catalog",
}

const run = (cmd, args, cwd) => execFileSync(cmd, args, { cwd, stdio: "inherit" })

// The scratch tree mirrors what a consumer sees: one `node_modules` holding
// every dependency the host and the trait resolve, with the trait itself
// extracted from its tarball rather than linked.
const linkNodeModules = (from, into) => {
  for (const entry of readdirSync(from)) {
    if (entry === ".pnpm" || entry === ".modules.yaml") continue
    const src = join(from, entry)
    const dst = join(into, entry)
    if (entry.startsWith("@")) {
      mkdirSync(dst, { recursive: true })
      for (const scoped of readdirSync(src)) {
        if (!existsSync(join(dst, scoped))) symlinkSync(join(src, scoped), join(dst, scoped))
      }
    } else if (!existsSync(dst)) {
      symlinkSync(src, dst)
    }
  }
}

let failed = false
for (const [traitDir, hostDir] of Object.entries(specimens)) {
  const traitPkg = JSON.parse(readFileSync(join(root, traitDir, "package.json"), "utf8"))
  const scratch = mkdtempSync(join(tmpdir(), "trait-pack-"))
  console.log(`\n[check-trait-pack] ${traitPkg.name} → ${hostDir}  (${scratch})`)
  try {
    run("pnpm", ["pack", "--pack-destination", scratch], join(root, traitDir))
    const tarball = readdirSync(scratch).find((f) => f.endsWith(".tgz"))

    const modules = join(scratch, "node_modules")
    mkdirSync(modules, { recursive: true })
    linkNodeModules(join(root, "node_modules"), modules)
    linkNodeModules(join(root, hostDir, "node_modules"), modules)
    // The trait's own dependencies resolve from the extracted dir upward, so a
    // link the trait needs but the host does not must be present too.
    if (existsSync(join(root, traitDir, "node_modules"))) linkNodeModules(join(root, traitDir, "node_modules"), modules)

    // The host's workspace link to the trait is replaced by the tarball's contents.
    const installed = join(modules, ...traitPkg.name.split("/"))
    rmSync(installed, { recursive: true, force: true })
    mkdirSync(installed, { recursive: true })
    run("tar", ["-xzf", join(scratch, tarball), "--strip-components=1", "-C", installed])

    const host = join(scratch, "host")
    cpSync(join(root, hostDir), host, {
      recursive: true,
      filter: (p) => !p.includes("/node_modules") && !p.includes("/lib/"),
    })
    // No `lib/` is shipped: the consumer compiles the trait from its sources.
    if (existsSync(join(installed, "lib"))) throw new Error("tarball ships lib/")
    run("pnpm", ["exec", "rescript", "build"], host)
    console.log(`[check-trait-pack] ok: ${traitPkg.name} builds from its tarball`)
  } catch (err) {
    failed = true
    console.error(`[check-trait-pack] FAILED: ${traitPkg.name} — ${err.message}`)
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}
process.exit(failed ? 1 : 0)
