#!/usr/bin/env node
// Count fields and object types in a DEPLOYED AppSync schema that carry no auth
// directive.
//
// An undirectived field or type is reachable by ANY authenticated Cognito
// caller, and there is no backstop underneath: `userPoolConfig.defaultAction`
// is forced to ALLOW, because AWS refuses DENY on an API that has an additional
// auth provider ("Additional authentication providers cannot be specified when
// setting DENY for top level user pool authentication type") and every API here
// configures AWS_IAM. So zero is not an optimisation here — it is the whole
// protection.
//
// The deploy path already enforces this in-process
// (`AppSync_SdlDecorate.assertGateable` refuses to return an ungateable schema).
// This script is the independent check on what is actually DEPLOYED, which
// catches what the in-process invariant cannot see: drift introduced outside our
// deploy, and any path that reaches AppSync without passing through assembly.
//
// Read the DEPLOYED schema, never a locally rendered one. The gap this script
// exists to catch is fields injected by paths that never reach the auth
// decoration — `_noop`, added by the stitcher during assembly, was live on three
// APIs — and local rendering of a decorated fragment does not reveal them.
//
// Usage:
//   node scripts/check-appsync-directive-coverage.mjs --api-id <id> [--region eu-west-1]
//   node scripts/check-appsync-directive-coverage.mjs --file schema.graphql
//
// Exit 0 = fully covered, 1 = gaps listed (each is open to any authenticated caller).

import { execFileSync } from 'node:child_process'
import { readFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const args = new Map()
for (let i = 2; i < process.argv.length; i += 2) {
  args.set(process.argv[i].replace(/^--/, ''), process.argv[i + 1])
}

const region = args.get('region') ?? 'eu-west-1'
const apiId = args.get('api-id')
const file = args.get('file')

if (!apiId && !file) {
  console.error('need --api-id <id> or --file <schema.graphql>')
  process.exit(1)
}

const readSchema = () => {
  if (file) return readFileSync(file, 'utf8')
  const out = join(mkdtempSync(join(tmpdir(), 'appsync-sdl-')), 'schema.graphql')
  execFileSync('aws', [
    'appsync', 'get-introspection-schema',
    '--region', region, '--api-id', apiId,
    '--format', 'SDL', '--include-directives', out,
  ], { stdio: ['ignore', 'ignore', 'inherit'] })
  return readFileSync(out, 'utf8')
}

const sdl = readSchema()
const gaps = { Query: [], Mutation: [], Subscription: [], types: [] }

// Root-operation fields. Introspection SDL puts each field on one line with its
// directives appended, so a line-level check is sound here.
for (const block of ['Query', 'Mutation', 'Subscription']) {
  const m = sdl.match(new RegExp(`^type ${block}\\b[^{]*\\{([\\s\\S]*?)^\\}`, 'm'))
  if (!m) continue
  for (const line of m[1].split('\n')) {
    if (!/^ {2}\w+/.test(line)) continue
    if (!line.includes('@aws_')) gaps[block].push(line.trim().match(/^(\w+)/)[1])
  }
}

// Only `type` declarations take auth directives — input/enum/union/interface do not.
for (const m of sdl.matchAll(/^type (\w+)([^{]*)\{/gm)) {
  if (!m[2].includes('@aws_')) gaps.types.push(m[1])
}

const total = Object.values(gaps).reduce((n, xs) => n + xs.length, 0)
const label = apiId ?? file

for (const [kind, xs] of Object.entries(gaps)) {
  if (xs.length) console.log(`${kind}: ${xs.length} undirectived\n    ${xs.join('\n    ')}`)
}

if (total === 0) {
  console.log(`${label}: fully covered — every field and type carries an enforced directive`)
  process.exit(0)
}
console.log(`\n${label}: ${total} undirectived — each is open to ANY authenticated Cognito caller`)
process.exit(1)
