#!/usr/bin/env node
/**
 * Validates every AppSync JS resolver this repo generates against AppSync's own
 * compiler, offline, before a deploy tries to attach one.
 *
 * Why this exists: APPSYNC_JS is type-checked and linted server-side, and a
 * resolver AppSync refuses is reported at CreateResolver time as the opaque
 * "The code contains one or more errors". Pulumi surfaces that with no line, no
 * rule, and no indication of which of the ~100 resolvers a stack creates is at
 * fault — and the run stops at the first one, so a second defect costs another
 * full deploy to find. `EvaluateCode` gives the file, line and rule directly,
 * for every template at once, in about a minute.
 *
 * Two classes of defect it has caught, both invisible to `rescript build` and to
 * every unit test, because the generated code is a *string* until AWS reads it:
 *   - a stub arity mismatch (`const _owns = () => true` called as `_owns(row)`),
 *     which is TS2554 to the resolver compiler and fine to every JS parser;
 *   - a `try` statement, which APPSYNC_JS forbids outright (`no-try`).
 *
 * Requires AWS credentials (EvaluateCode is an API call, but touches no stack
 * and creates nothing). Without them the check SKIPS rather than fails, so a
 * contributor with no AWS account is never blocked by it.
 *
 * Usage:  node ./scripts/check-appsync-resolvers.mjs [--verbose]
 */

import { AppSyncClient, EvaluateCodeCommand } from '@aws-sdk/client-appsync'
import * as F from '../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res.mjs'
import * as Lambda from '../reventless/aws/src/adapter/QueryDb/QueryDbResolvers_Lambda.res.mjs'

const VERBOSE = process.argv.includes('--verbose')
const REGION = process.env.AWS_REGION ?? 'eu-west-1'
const RUNTIME = { name: 'APPSYNC_JS', runtimeVersion: '1.0.0' }
const CONCURRENCY = 6

// A context wide enough that a template reaches the end of its own body. Runtime
// errors are not what this checks — a resolver that throws on this context still
// compiled, which is the property under test — but a context that satisfies the
// common shapes keeps the output readable.
const CONTEXT = JSON.stringify({
  arguments: { id: 'x', ids: ['x'] },
  args: { id: 'x', ids: ['x'] },
  source: {},
  stash: {},
  prev: { result: {} },
  identity: { sub: 'u', username: 'u', claims: { 'cognito:groups': [] } },
  result: { items: [{ id: 'x' }], data: { TestTable: [] } },
})

const OWNERS = [undefined, 'ownerId']
// No retirement, the boolean form, and the state form — the three shapes the
// generated guards branch on.
const RETIREMENTS = [
  [undefined, undefined],
  ['archived', undefined],
  ['lifecycle', ['Archived', 'Discontinued']],
]
const ELEVATED = ['Admin']

/** @returns {Array<[string, string]>} [name, code] for every unit to validate. */
const generateUnits = () => {
  const units = []
  // A curried template that was under-applied is still a function, and
  // stringifying one yields its compiler output ($staropt$star, unbound
  // parameter names) — a defect report about code no deploy ever attaches.
  const push = (name, code) => {
    if (typeof code === 'function')
      throw new Error(`${name}: template under-applied — it returned a function, not resolver code.`)
    units.push([name, typeof code === 'string' ? code : String(code)])
  }

  for (const owner of OWNERS) {
    for (const [retiredField, retiredValues] of RETIREMENTS) {
      const tag = `${owner ? 'owned' : 'unowned'}_${retiredField ?? 'live'}`
      push(`batchGetItemsByIds__${tag}`, F.batchGetItemsByIds(owner, retiredField, retiredValues, ELEVATED)('TestTable'))
      push(`getItemById__${tag}`, F.getItemById(owner, ELEVATED, retiredField, retiredValues))
      push(`ownerScopedResultResponse__${tag}`, F.ownerScopedResultResponse(owner, ELEVATED, retiredField, retiredValues))
      push(`ownerScopedFirstResultResponse__${tag}`, F.ownerScopedFirstResultResponse(owner, ELEVATED, retiredField, retiredValues))
      push(`queryByIdSort__${tag}`, F.queryByIdSort('placedAt', owner, ELEVATED, retiredField, retiredValues))
      push(`queryByIndexFiltered__${tag}`, F.queryByIndexFiltered('byCat', 'catId', owner, retiredField, retiredValues, ELEVATED))
      push(`queryByIndexSortFiltered__${tag}`, F.queryByIndexSortFiltered('byCust', 'custId', owner, 'placedAt', retiredField, retiredValues, ELEVATED))
      push(`listAllItemsConnection__${tag}`, F.listAllItemsConnection('name', ['kind'], ['price'], ['name'], false, owner, ELEVATED, retiredField, retiredValues))
      // `namedWhenRetired` changes which rows the reference door lets through,
      // so both arms are generated code worth compiling.
      for (const named of [true, false])
        push(`refsByIds__${tag}_named${named}`, F.refsByIds('name', retiredField, retiredValues, named, owner, ELEVATED)('TestTable'))
      // `@resolvesMany` carries the target's guards, and a target with a sort
      // key builds a two-part BatchGetItem key — both arms are generated code.
      for (const sort of [undefined, 'sk'])
        push(`resolveIds__${tag}_sort${sort ?? 'none'}`,
          F.resolveIds('ids', sort, owner, retiredField, retiredValues, ELEVATED)('TestTable'))
    }
  }

  push('queryItemsWithSortConditions__owned', F.queryItemsWithSortConditions('placedAt', 'ownerId', ELEVATED))
  push('queryItemsWithSortConditions__unowned', F.queryItemsWithSortConditions('placedAt', undefined, ELEVATED))
  push('authorizeIndexedAccess', F.authorizeIndexedAccess('byCat', 'Admin'))
  push('authorizeIndexedAccessRequest', F.authorizeIndexedAccessRequest('byCat', 'Admin'))
  push('authorizeIndexedAccessResponse', F.authorizeIndexedAccessResponse('byCat'))
  push('addItemToList', F.addItemToList('items', 'item'))
  push('invokeCommandGenerator', F.invokeCommandGenerator('Add'))
  push('invokeDcbMutation', F.invokeDcbMutation('tag'))
  push('invokeInboundTranslation', F.invokeInboundTranslation('fieldIn'))
  push('nodeDecodeGlobalId', F.nodeDecodeGlobalId)
  push('nodeGetItemForType', F.nodeGetItemForType('Product'))
  push('queryByIndex', F.queryByIndex('byCat'))
  push('queryByIndexDeletable', F.queryByIndexDeletable('byCat'))
  push('queryByIndexSort', F.queryByIndexSort('byCust', 'custId', 'placedAt'))
  push('resolveId', F.resolveId('catId'))
  push('resolveIdByIndex', F.resolveIdByIndex('byCat', 'catId', 'id'))
  push('resolveIdByIndexSort', F.resolveIdByIndexSort('byCat', 'catId', 'sub', 'id', 'sk'))
  push('resolveIdByIndexSortArgument', F.resolveIdByIndexSortArgument('byCat', 'catId', 'arg', 'id', 'sk'))
  push('resolveIdResult', F.resolveIdResult('TestTable', 'id'))
  push('resolveIdResults', F.resolveIdResults('TestTable', 'id'))
  push('resolveIdSort', F.resolveIdSort('catId', 'sub', 'sk'))
  push('resolveIdSortArgument', F.resolveIdSortArgument('catId', 'arg', 'sk'))
  push('resolveIdsResult', F.resolveIdsResult('TestTable', 'ids'))

  for (const name of ['deleteItem', 'firstResult', 'firstResultResponseCode', 'indexConnectionResponseCode',
    'listAllItems', 'pipelinePassThrough', 'putItem', 'queryById', 'result', 'resultList',
    'resultListResponseCode', 'resultResponseCode'])
    push(name, F[name])

  // The Postgres read models reach their Lambda through templates of their own.
  push('invokeTemplate__plain', Lambda.invokeTemplate('Products', 'list', undefined, undefined, undefined))
  push('invokeTemplate__index', Lambda.invokeTemplate('Products', 'index', 'byCat', undefined, undefined))
  push('invokeTemplate__auth', Lambda.invokeTemplate('Products', 'list', undefined, 'AuthTable', 'Admin'))
  push('invokeTemplate__full', Lambda.invokeTemplate('Products', 'index', 'byCat', 'AuthTable', 'Admin'))
  push('invokeFieldTemplate__plain', Lambda.invokeFieldTemplate('Products', 'resolveOne', 'Categories', ''))
  push('invokeFieldTemplate__subField', Lambda.invokeFieldTemplate('Products', 'resolveOne', 'Categories', "\n      sourceSubId: { kind: 'field', name: 'sub' },"))
  push('invokeFieldTemplate__subArg', Lambda.invokeFieldTemplate('Products', 'resolveOne', 'Categories', "\n      sourceSubId: { kind: 'arg', name: 'a' },"))
  push('invokeFieldTemplate__many', Lambda.invokeFieldTemplate('Products', 'resolveMany', 'Categories', "\n      sourceIdsField: 'ids',"))

  return units
}

/**
 * Several templates are half-units — a response body meant to be concatenated
 * onto a request, or the reverse. AppSync compiles a whole file, so the missing
 * half is supplied here. What is added is inert and never the thing under test.
 * @returns {string | null} null when the template is a fragment with neither half.
 */
const toCompilableUnit = (raw) => {
  let code = raw
  const hasRequest = /export function request/.test(code)
  const hasResponse = /export function response/.test(code)
  if (!hasRequest && !hasResponse) return null
  if (!/import\s*\{[^}]*\butil\b/.test(code)) code = `import { util } from '@aws-appsync/utils';\n${code}`
  if (/\bruntime\./.test(code) && !/import\s*\{[^}]*\bruntime\b/.test(code))
    code = `import { runtime } from '@aws-appsync/utils';\n${code}`
  if (!hasRequest)
    code = code.replace(/export function response/, 'export function request(ctx) { return {}; }\nexport function response')
  if (!hasResponse) code += '\nexport function response(ctx) { return ctx.result; }\n'
  return code
}

const client = new AppSyncClient({ region: REGION, maxAttempts: 5 })

const sleep = (ms) => new Promise(r => setTimeout(r, ms))

/**
 * True when the environment cannot reach AppSync at all — no credentials, no
 * permission, no DNS. That is a reason to skip the whole check; a throttle or a
 * timeout is not, and is retried instead.
 */
const isMissingAccess = (err) => {
  const text = `${err?.name ?? ''} ${err?.message ?? ''}`
  return /Credentials|CredentialsProviderError|UnrecognizedClient|AccessDenied|UnauthorizedException|InvalidSignature|ENOTFOUND|EAI_AGAIN/i.test(text)
}

/**
 * EvaluateCode is rate-limited, and this sends ~100 calls. A throttle or a
 * transient 5xx says nothing about the resolver, so it is retried rather than
 * reported: a gate that fails the deploy over an API hiccup would be worse than
 * no gate, because the reflex becomes to ignore it.
 * @returns {Promise<{name: string, errors: string[], skipped?: boolean}>}
 */
const validate = async ([name, raw], attempt = 0) => {
  const code = toCompilableUnit(raw)
  if (code === null) return { name, errors: [], skipped: true }
  try {
    const res = await client.send(new EvaluateCodeCommand({ runtime: RUNTIME, code, function: 'response', context: CONTEXT }))
    // `error` alone is the template throwing on the synthetic context, which
    // says nothing about whether AppSync would accept it. `codeErrors` is the
    // refusal.
    const errors = (res.error?.codeErrors ?? []).map(e => (e.value ?? '').trim())
    return { name, errors }
  } catch (err) {
    if (isMissingAccess(err)) throw err
    if (attempt >= 3) return { name, errors: [], unavailable: `${err?.name ?? 'Error'}: ${err?.message ?? ''}`.trim() }
    await sleep(2 ** attempt * 500)
    return validate([name, raw], attempt + 1)
  }
}

const run = async () => {
  const units = generateUnits()
  const results = []
  for (let i = 0; i < units.length; i += CONCURRENCY)
    results.push(...await Promise.all(units.slice(i, i + CONCURRENCY).map(u => validate(u))))

  const failed = results.filter(r => r.errors.length > 0)
  const skipped = results.filter(r => r.skipped)
  const unavailable = results.filter(r => r.unavailable)
  const checked = results.length - skipped.length - unavailable.length

  if (VERBOSE) for (const r of results.filter(r => !r.skipped && !r.unavailable && !r.errors.length)) console.log(`  ok    ${r.name}`)
  for (const r of failed) {
    console.error(`\n  FAIL  ${r.name}`)
    for (const e of r.errors) console.error(`        ${e}`)
  }

  if (failed.length > 0) {
    console.error(`\n${failed.length} of ${checked} resolver unit(s) would be refused by AppSync at deploy time.`)
    console.error('The deploy fails on the first one with "The code contains one or more errors"; fix the template that generates it.')
    return 1
  }

  console.log(`ok  ${checked} AppSync resolver units compile (APPSYNC_JS ${RUNTIME.runtimeVersion})`)
  if (skipped.length) console.log(`    ${skipped.length} fragment(s) not independently compilable, skipped`)
  // Reported, never fatal: an unreachable API leaves those units unproven, but
  // the deploy that follows exercises them for real. Failing here would block a
  // release on AWS being briefly slow.
  if (unavailable.length) {
    console.log(`    ${unavailable.length} unit(s) could not be checked (API unavailable after retries):`)
    for (const r of unavailable.slice(0, 3)) console.log(`      ${r.name} — ${r.unavailable}`)
  }
  return 0
}

try {
  process.exitCode = await run()
} catch (err) {
  // No credentials, no permission, no network: skip rather than fail. This
  // check costs a round trip to AWS and must never be the reason a contributor
  // without an account cannot run the repo's checks.
  if (isMissingAccess(err)) {
    console.log(`skipped  AppSync resolver validation needs AWS access (${err?.name ?? 'unavailable'})`)
    process.exitCode = 0
  } else {
    throw err
  }
}
