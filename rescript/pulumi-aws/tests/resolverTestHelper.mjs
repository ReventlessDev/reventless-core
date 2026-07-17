/**
 * Evaluates an AppSync JS resolver code string and returns the exported
 * { request, response } functions, with @aws-appsync/utils mocked.
 *
 * Approach: strip the import statement (it's mocked via Jest moduleNameMapper
 * when importing from .res.mjs files, but here we inline the mock) and
 * evaluate the code with the mock injected into scope via Function constructor.
 */
import * as appsyncUtils from './__mocks__/appsync-utils.mjs'

const { util, runtime } = appsyncUtils

/**
 * Parse a resolver code string into callable { request, response } functions.
 * Strips ES module syntax (import/export) and evaluates with mocked utils.
 */
export function evalResolver(code) {
  // Strip import statements (mocked externally)
  let stripped = code.replace(/^import\s+.*?from\s+['"][^'"]+['"];?\s*/gm, '')
  // Replace `export function X` with `__exports.X = function X`
  stripped = stripped.replace(/export\s+function\s+(\w+)/g, '__exports.$1 = function $1')

  const __exports = {}
  // eslint-disable-next-line no-new-func
  new Function('util', 'runtime', '__exports', stripped)(util, runtime, __exports)
  return __exports
}

/** Convenience: make a minimal ctx object with optional overrides. */
export function makeCtx(overrides = {}) {
  return {
    args: {},
    identity: {
      username: 'testuser',
      sub: 'user-sub-123',
      sourceIp: ['1.2.3.4'],
      claims: { 'cognito:groups': [] },
    },
    result: null,
    source: {},
    error: null,
    info: { fieldName: 'testField', parentTypeName: 'Query' },
    stash: {},
    ...overrides,
  }
}
