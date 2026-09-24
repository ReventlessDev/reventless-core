#!/usr/bin/env node
// Record the newest complete reventless-ppx release in git: the version, and the
// optionalDependencies pin on its per-platform binaries.
//
// "Complete" means main AND every pinned binary are served at that version. The
// registry makes a version visible minutes after `npm publish` returns, and each
// package on its own schedule, so a release is pinned only once all of it can be
// installed — a pin to a binary pnpm cannot resolve yet is dropped from the
// lockfile, which breaks every frozen install. Nothing waits for that here:
// pin-ppx.yml runs this again later, and the version is pinned then.
//
// Only versions in the checked-out version's line count (1.0.0-alpha.N on an
// alpha branch), so a branch never pins another branch's release.
//
// Rewrites packages/reventless-ppx/package.json and prints the version when git
// is behind; prints nothing when it is not.
//
// Usage:
//   node scripts/pin-ppx.mjs            # rewrite and print, or print nothing
//   node scripts/pin-ppx.mjs --explain  # ...and say why on stderr

import { readFileSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const MANIFEST = join(ROOT, 'packages/reventless-ppx/package.json')
const REGISTRY = 'https://registry.npmjs.org'
const PLATFORM_PREFIX = '@reventlessdev/reventless-ppx-'
const explain = process.argv.includes('--explain')

const note = (msg) => {
  if (explain) console.error(msg)
}

/** `1.0.0-alpha.94` → [`1.0.0-alpha.`, 94]. Throws on a shape it cannot order,
    as resolve-ppx-version.mjs does, rather than guessing. */
const split = (version) => {
  const m = version.match(/^(.*[-.])(\d+)$/)
  if (!m) throw new Error(`cannot order ${version}: it does not end in a number`)
  return [m[1], Number(m[2])]
}

/** Versions the registry serves for one package, read past the CDN's
    five-minute metadata cache (see resolve-ppx-version.mjs). */
const servedVersions = async (name) => {
  const res = await fetch(`${REGISTRY}/${name.replace('/', '%2F')}?fresh=${Date.now()}`)
  if (res.status === 404) return new Set()
  if (!res.ok) throw new Error(`registry lookup for ${name} failed: ${res.status} ${res.statusText}`)
  return new Set(Object.keys((await res.json()).versions || {}))
}

const main = async () => {
  const manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'))
  const platforms = Object.keys(manifest.optionalDependencies || {}).filter((k) =>
    k.startsWith(PLATFORM_PREFIX),
  )
  const [line, current] = split(manifest.version)
  const names = [manifest.name, ...platforms]

  const served = await Promise.all(names.map(servedVersions))
  const complete = [...served[0]]
    .filter((v) => served.every((set) => set.has(v)))
    .filter((v) => v.startsWith(line) && /^\d+$/.test(v.slice(line.length)))
    .map((v) => split(v)[1])
  if (complete.length === 0) {
    note(`no version of the ${line}N line is served on all of: ${names.join(', ')}`)
    return
  }
  const newest = Math.max(...complete)
  const version = `${line}${newest}`
  const want = `^${version}`
  const pinned = platforms.every((k) => manifest.optionalDependencies[k] === want)
  if (newest < current || (newest === current && pinned)) {
    note(`git records ${manifest.version}; the newest complete release is ${version} — nothing to pin`)
    return
  }

  manifest.version = version
  for (const k of platforms) manifest.optionalDependencies[k] = want
  writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + '\n')
  note(`pinned ${version} (git recorded ${`${line}${current}`})`)
  console.log(version)
}

main().catch((err) => {
  console.error(`pin-ppx: ${err.message}`)
  process.exit(1)
})
