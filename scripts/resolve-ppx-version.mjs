#!/usr/bin/env node
// Resolve a version reventless-ppx can actually publish under, across EVERY
// package the release consists of.
//
// The release is one main package plus one package per platform, and a version
// is only usable if it is free on all of them. Checking main alone is what let
// a half-published version through: the per-platform binaries existed, main did
// not, so the gate passed — and the publish then either 409'd or, worse, kept
// the stale binaries and shipped a main that pointed at them.
//
// Reusing a version is impossible to repair, because a published tarball cannot
// be replaced. So the only safe move is to step past it, and doing that here —
// in one run, rather than by failing and asking for a second push — is what
// makes a PPX source change a single push again.
//
// The registry is read over HTTP rather than through `npm view`: the npm CLI
// caches 404s, and a cached 404 here reads as "free" for a version that is not.
//
// Usage:
//   node scripts/resolve-ppx-version.mjs           # print the resolved version
//   node scripts/resolve-ppx-version.mjs --explain # ...and say why on stderr

import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const PPX = join(ROOT, 'packages/reventless-ppx')
const REGISTRY = 'https://registry.npmjs.org'
const explain = process.argv.includes('--explain')

const note = (msg) => {
  if (explain) console.error(msg)
}

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'))

/** Every package name this release publishes: main, plus each platform scaffold
    — including ones CI does not build (darwin-x64 is published by hand), because
    a version claimed by any of them is a version this release cannot reuse. */
const packageNames = () => {
  const names = [readJson(join(PPX, 'package.json')).name]
  const npmDir = join(PPX, 'npm')
  for (const entry of readdirSync(npmDir)) {
    const manifest = join(npmDir, entry, 'package.json')
    if (existsSync(manifest)) names.push(readJson(manifest).name)
  }
  return names
}

/** The set of versions already on the registry for one package. A package that
    has never been published 404s, which is an empty set rather than an error. */
const publishedVersions = async (name) => {
  const res = await fetch(`${REGISTRY}/${name.replace('/', '%2F')}`)
  if (res.status === 404) return new Set()
  if (!res.ok) {
    throw new Error(`registry lookup for ${name} failed: ${res.status} ${res.statusText}`)
  }
  const body = await res.json()
  return new Set(Object.keys(body.versions || {}))
}

/** Bump the trailing integer of a prerelease (1.0.0-alpha.71 -> 1.0.0-alpha.72),
    or of the patch when there is no prerelease. Throws rather than guessing at a
    shape it does not recognise — a wrong bump publishes under a version nobody
    expects, which is worse than stopping. */
const bump = (version) => {
  const pre = version.match(/^(.*[-.])(\d+)$/)
  if (pre) return `${pre[1]}${Number(pre[2]) + 1}`
  throw new Error(
    `cannot bump ${version} automatically — it does not end in a number. ` +
      `Set packages/reventless-ppx/package.json to the intended next version by hand.`,
  )
}

const main = async () => {
  const names = packageNames()
  const start = readJson(join(PPX, 'package.json')).version
  note(`packages in this release: ${names.join(', ')}`)

  const taken = new Map()
  for (const name of names) taken.set(name, await publishedVersions(name))

  let version = start
  // Bounded so a misread registry cannot spin forever; 50 is far past any real
  // backlog of claimed versions.
  for (let i = 0; i < 50; i++) {
    const claimedBy = names.filter((n) => taken.get(n).has(version))
    if (claimedBy.length === 0) {
      if (version !== start) {
        note(`${start} is claimed — resolved forward to ${version}`)
      } else {
        note(`${version} is free on every package`)
      }
      console.log(version)
      return
    }
    note(`${version} is already published on: ${claimedBy.join(', ')}`)
    version = bump(version)
  }
  throw new Error(`no free version found within 50 bumps of ${start}`)
}

main().catch((err) => {
  console.error(`resolve-ppx-version: ${err.message}`)
  process.exit(1)
})
