#!/usr/bin/env node
// Probe whether a deployed AppSync API actually enforces its Cognito group gates.
//
// The gate this checks used to fail open: the adapter emitted the single-mode
// `@aws_auth(cognito_groups: [...])`, which AppSync ignores on a multi-auth API,
// leaving every "admin only" field readable and writable by any authenticated
// Cognito user. See docs/plans/appsync-group-authorization-unenforced.md.
//
// This cannot be a unit test — the behaviour lives in the service, not in our
// SDL. Run it against a deployment after any change to the auth decoration.
//
// Usage:
//   node scripts/probe-appsync-group-gate.mjs \
//     --endpoint https://xxx.appsync-api.eu-west-1.amazonaws.com/graphql \
//     --client-id <cognitoAppClientId> \
//     --region eu-west-1 \
//     --query 'query { Platform_ComponentDefinitions { pluginId } }' \
//     --in-group-user <username> --in-group-pass <password> \
//     --no-group-user <username> --no-group-pass <password>
//
// Create throwaway users for this; do not reuse credentials CI depends on.
// Exit code 0 = gate enforced, 1 = gate open (or the probe could not run).

const args = new Map()
for (let i = 2; i < process.argv.length; i += 2) {
  args.set(process.argv[i].replace(/^--/, ''), process.argv[i + 1])
}

const need = (k) => {
  const v = args.get(k)
  if (!v) {
    console.error(`missing --${k}`)
    process.exit(1)
  }
  return v
}

const endpoint = need('endpoint')
const clientId = need('client-id')
const region = args.get('region') ?? 'eu-west-1'
const query = need('query')

const login = async (username, password) => {
  const res = await fetch(`https://cognito-idp.${region}.amazonaws.com/`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-amz-json-1.1',
      'X-Amz-Target': 'AWSCognitoIdentityProviderService.InitiateAuth',
    },
    body: JSON.stringify({
      AuthFlow: 'USER_PASSWORD_AUTH',
      ClientId: clientId,
      AuthParameters: { USERNAME: username, PASSWORD: password },
    }),
  })
  const body = await res.json()
  if (!res.ok) throw new Error(`login failed for ${username}: ${JSON.stringify(body)}`)
  return body.AuthenticationResult.IdToken
}

const call = async (token) => {
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: token } : {}) },
    body: JSON.stringify({ query }),
  })
  return { status: res.status, body: await res.text() }
}

// A refusal is either the transport 401 (unauthenticated) or a field error with
// no data (unentitled). Data coming back means the gate did not run.
const refused = ({ status, body }) => {
  if (status === 401) return true
  try {
    const j = JSON.parse(body)
    return Array.isArray(j.errors) && j.errors.length > 0 && (j.data == null || Object.values(j.data).every((v) => v == null))
  } catch {
    return false
  }
}

const report = (label, r, expectRefused) => {
  const ok = refused(r) === expectRefused
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}`)
  console.log(`      HTTP ${r.status}  ${r.body.slice(0, 240).replace(/\s+/g, ' ')}`)
  return ok
}

const main = async () => {
  const results = []

  results.push(report('no token → refused', await call(null), true))
  results.push(report('malformed token → refused', await call('not-a-real-jwt'), true))

  const inGroupUser = args.get('in-group-user')
  const noGroupUser = args.get('no-group-user')

  if (inGroupUser) {
    const tok = await login(inGroupUser, need('in-group-pass'))
    results.push(report('valid token, IN the group → allowed', await call(tok), false))
  } else {
    console.log('SKIP  valid token, IN the group (no --in-group-user)')
  }

  let decisiveRowRan = false
  if (noGroupUser) {
    const tok = await login(noGroupUser, need('no-group-pass'))
    // The finding: this row returned HTTP 200 with full data.
    results.push(report('valid token, NO groups → refused', await call(tok), true))
    decisiveRowRan = true
  } else {
    console.log('SKIP  valid token, NO groups (no --no-group-user) — this is THE row; supply it')
  }

  const failed = results.filter((r) => !r).length
  if (failed > 0) {
    console.log(`\n${failed} row(s) wrong — gate is NOT behaving as intended`)
    process.exit(1)
  }
  // Without the no-group caller the unauthenticated rows prove only that the
  // transport rejects garbage — which held even while the gate was wide open.
  // Reporting "enforced" here would be the same false pass the gate itself gave.
  if (!decisiveRowRan) {
    console.log('\nINCONCLUSIVE — the rows that ran passed, but the no-group caller is the only one that tests the gate')
    process.exit(1)
  }
  console.log('\ngate enforced')
  process.exit(0)
}

main().catch((e) => {
  console.error(e.message)
  process.exit(1)
})
