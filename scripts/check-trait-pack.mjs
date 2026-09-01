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
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")

// trait dir → the host that binds it, and — for a trait that ships a scaffold —
// the graft to emit into a scratch copy of that host.
//
// `graft` turns the check from "the package installs" into the stronger claim
// the emitter exists to support: that what it writes COMPILES and SATISFIES THE
// TRAIT'S OWN RULES, with no host policy written at all. A graft with no extra
// refusal is a complete graft, so a policy-free emit is a legitimate one — which
// is what makes it checkable without modelling anyone's policy.
//
// Deliberately not a diff against the committed specimen host: reproducing that
// would mean the emitter knowing about `Product`'s shelf and `Category`'s
// boolean, and modelling host policy is exactly what makes scaffolders rot.
//
// `graft.remove` is the aggregate-host variant of the same claim. An aggregate
// graft cannot land on a fresh entity — its conformance binding names the host's
// own `Spec` and `Behavior`, and those carry the lifecycle policy a trait must
// not write. So instead of emitting beside the specimen, the check DELETES the
// files the trait owns and emits them back. Nothing is diffed; the files have to
// build and conform, which is the property that matters. The aggregate and its
// behavior — the half the trait only prints patches for — stay untouched, so
// what is proven is exactly the emitted half.
const specimens = {
  "traits/address-geocoding": {
    host: "examples/online-shop-hybrid/ordering",
    graft: {
      args: [
        "--entity", "Customer", "--entityId", "customerId", "--created", "Registered",
        "--createdFields", "email: string", "--createdValues", 'email: "alice@x.y"',
        "--externalSystem", "AwsLocation", "--transition", "Customers.Active",
      ],
      into: "src/Customer",
      tests: "tests/Customer",
      // Written by the trait, so removed before the emit: `graft-trait` refuses
      // to overwrite, and a skipped write would leave the check proving nothing.
      remove: [
        "src/Customer/OutboundTranslationSlice/GeocodeCustomerAddress.res",
        "src/Customer/OutboundTranslationSlice/GeocodeCustomerAddress_Translation.res",
        "tests/Customer/AddressGeocodingConformance_GWT.res",
      ],
      conformance: "tests/Customer/AddressGeocodingConformance_GWT.res.mjs",
    },
  },
  "traits/attachments": {
    host: "examples/online-shop-hybrid/catalog",
    graft: {
      // A fresh entity, so the emit collides with nothing the host already owns
      // and the conformance suite runs against emitted code alone.
      args: [
        "--entity", "Gadget", "--entityId", "gadgetId", "--noun", "Image",
        "--file", "gadgetImage", "--created", "GadgetAdded", "--view", "Gadgets",
      ],
      into: "src/Gadget",
      tests: "tests/Gadget",
      // The suite the emitted binding registers, run against what was emitted.
      conformance: "tests/Gadget/GadgetImagesConformance_GWT.res.mjs",
    },
  },
  // The SelfContained shape: the graft is a set of new components rather than
  // arms on something the host already had, so a fresh chapter of a host that
  // has never heard of notifications is the honest emit target. Nothing here
  // exists in the catalog plugin, which is the point — what compiles and conforms
  // afterwards was written by the trait alone.
  //
  // The two relays are printed rather than written, so they are not in this
  // check's blast radius: what a host's events MEAN is the part a trait cannot be
  // told in names, and a check that emitted them would be checking a guess.
  "traits/notification": {
    host: "examples/online-shop-hybrid/catalog",
    graft: {
      args: [
        "--chapter", "Subscriber", "--noun", "Subscriber",
        "--categories", "StockAlert,PriceDrop,Marketing",
        "--transactional", "StockAlert",
        "--contactSource", "Product", "--contactEvents", "ProductAdded",
        "--contactField", "email",
        "--occurrence", "ProductAdded", "--occurrenceId", "productId",
        "--occurrenceRecipient", "subscriberId", "--occurrenceCategory", "StockAlert",
      ],
      into: "src/Subscriber",
      tests: "tests/Subscriber",
      conformance: "tests/Subscriber/NotificationConformance_GWT.res.mjs",
    },
  },
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
for (const [traitDir, spec] of Object.entries(specimens)) {
  const hostDir = spec.host
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
    // The host needs `node_modules` at its OWN root, not merely above it: pnpm
    // builds a script's PATH from `<cwd>/node_modules/.bin` alone and does not
    // walk up, so a `generate-plugin` one directory higher is invisible to
    // `pnpm run generate`. Node and rescript resolve either way; pnpm does not.
    symlinkSync(modules, join(host, "node_modules"))
    // Declare the dependency, the way `pnpm add` would. A host that already
    // binds the trait has both lines; a host meeting it for the first time has
    // neither, and adding them here is what makes that case checkable at all —
    // otherwise a trait can only ever be proven against a host already wired for
    // it, which is the reverse of what install is supposed to demonstrate.
    for (const [file, add] of [
      ["rescript.json", (j) => { if (!j.dependencies.includes(traitPkg.name)) j.dependencies.push(traitPkg.name) }],
      ["package.json", (j) => { j.dependencies[traitPkg.name] ??= "workspace:*" }],
    ]) {
      const path = join(host, file)
      const json = JSON.parse(readFileSync(path, "utf8"))
      add(json)
      writeFileSync(path, JSON.stringify(json, null, 2) + "\n")
    }
    // No `lib/` is shipped: the consumer compiles the trait from its sources.
    if (existsSync(join(installed, "lib"))) throw new Error("tarball ships lib/")
    run("pnpm", ["exec", "rescript", "build"], host)
    console.log(`[check-trait-pack] ok: ${traitPkg.name} builds from its tarball`)

    if (spec.graft) {
      // pack → install → EMIT → generate-plugin → build → conform.
      for (const owned of spec.graft.remove ?? []) {
        rmSync(join(host, owned), { force: true })
        rmSync(join(host, owned.replace(/\.res$/, ".res.mjs")), { force: true })
      }
      const graftBin = join(modules, "@reventlessdev", "reventless-spec", "run-graft-trait.mjs")
      run("node", [graftBin, traitPkg.name,
        "--into", spec.graft.into, "--tests", spec.graft.tests, ...spec.graft.args], host)

      // The graft declares components, so the composition root must see them.
      run("pnpm", ["exec", "rescript", "build"], host)
      const generate = JSON.parse(readFileSync(join(host, "package.json"), "utf8")).scripts?.generate
      if (generate) run("pnpm", ["run", "generate"], host)
      run("pnpm", ["exec", "rescript", "build"], host)
      console.log(`[check-trait-pack] ok: ${traitPkg.name}'s emitted graft compiles`)

      // …and satisfies the trait's own rules. The binding was emitted whole, so
      // nothing between the trait's assertions and the emitted code was written
      // by a human.
      const suite = join(host, spec.graft.conformance)
      if (!existsSync(suite)) throw new Error(`emitted conformance suite missing: ${spec.graft.conformance}`)
      // `lib/bs/` holds a compiled copy of the same suite; without ignoring it
      // jest runs each assertion twice and the count stops meaning anything.
      run("node", ["--experimental-vm-modules", join(root, "node_modules", "jest", "bin", "jest.js"),
        "--rootDir", host, "--testMatch", `**/${spec.graft.conformance.split("/").pop()}`,
        "--testPathIgnorePatterns", "/lib/", "--testEnvironment", "node"], host)
      console.log(`[check-trait-pack] ok: ${traitPkg.name}'s emitted graft passes its conformance suite`)
    }
  } catch (err) {
    failed = true
    console.error(`[check-trait-pack] FAILED: ${traitPkg.name} — ${err.message}`)
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}
process.exit(failed ? 1 : 0)
