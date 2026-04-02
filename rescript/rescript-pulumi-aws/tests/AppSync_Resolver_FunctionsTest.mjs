import { evalResolver, makeCtx } from './resolverTestHelper.mjs'
import * as F from '../src/AppSync/AppSync_Resolver_Functions.res.mjs'

// ---------------------------------------------------------------------------
// Helper: all resolver code should include the appsync utils import
// ---------------------------------------------------------------------------
const hasUtilImport = code => code.includes("import { util } from '@aws-appsync/utils'")
const hasRequestFn = code => code.includes('export function request(') || code.includes('__exports.request')
const hasResponseFn = code => code.includes('export function response(') || code.includes('__exports.response')

// ---------------------------------------------------------------------------
// Structure: every exported code string must be a valid resolver module
// ---------------------------------------------------------------------------
describe('Resolver code structure', () => {
  // Labeled ReScript args compile to positional JS args in declaration order.
  const codeValues = [
    ['pipelinePassThrough', F.pipelinePassThrough],
    ['getItemById', F.getItemById],
    ['queryById', F.queryById],
    ['queryByIdSort(sortField)', F.queryByIdSort('status')],
    ['queryByIndex(index)', F.queryByIndex('userId')],
    ['queryByIndexDeletable(index)', F.queryByIndexDeletable('userId')],
    ['queryByIndexSort(index,idField,sortField)', F.queryByIndexSort('userId', 'userId', 'createdAt')],
    ['queryByIndexFiltered(index,idField)', F.queryByIndexFiltered('userId', 'userId')],
    ['queryByIndexSortFiltered(index,idField,sortField)', F.queryByIndexSortFiltered('userId', 'userId', 'status')],
    ['listAllItems', F.listAllItems],
    ['resolveId(sourceIdField)', F.resolveId('productId')],
    ['resolveIdSort(sourceIdField,sourceSortField,targetSortField)', F.resolveIdSort('productId', 'status', 'status')],
    ['resolveIdByIndex(index,sourceIdField,targetIdField)', F.resolveIdByIndex('productId', 'productId', 'productId')],
    ['putItem', F.putItem],
    ['addItemToList(listName,itemName)', F.addItemToList('items', 'itemId')],
    ['deleteItem', F.deleteItem],
    ['invokeCommandGenerator(cmd)', F.invokeCommandGenerator('CreateProduct')],
    ['invokeDcbMutation(tag)', F.invokeDcbMutation('Product')],
    ['invokeInboundTranslation(field)', F.invokeInboundTranslation('importProduct')],
    ['authorizeIndexedAccess(index,group)', F.authorizeIndexedAccess('userId', 'Admin')],
  ]

  test.each(codeValues)('%s includes util import', (_, code) => {
    expect(hasUtilImport(code)).toBe(true)
  })

  test.each(codeValues)('%s exports request function', (_, code) => {
    expect(hasRequestFn(code)).toBe(true)
  })

  test.each(codeValues)('%s exports response function', (_, code) => {
    expect(hasResponseFn(code)).toBe(true)
  })
})

// ---------------------------------------------------------------------------
// getItemById
// ---------------------------------------------------------------------------
describe('getItemById', () => {
  const { request, response } = evalResolver(F.getItemById)

  test('request returns GetItem with id key', () => {
    const ctx = makeCtx({ args: { id: 'abc123' } })
    const result = request(ctx)
    expect(result.operation).toBe('GetItem')
    expect(result.key.id).toEqual({ S: 'abc123' })
  })

  test('response returns ctx.result on success', () => {
    const ctx = makeCtx({ result: { id: 'abc123', name: 'Widget' } })
    expect(response(ctx)).toEqual({ id: 'abc123', name: 'Widget' })
  })

  test('response throws on ctx.error', () => {
    const ctx = makeCtx({ error: { message: 'not found', type: 'NotFound' } })
    expect(() => response(ctx)).toThrow('not found')
  })
})

// ---------------------------------------------------------------------------
// queryById
// ---------------------------------------------------------------------------
describe('queryById', () => {
  const { request, response } = evalResolver(F.queryById)

  test('request returns Query by id', () => {
    const ctx = makeCtx({ args: { id: 'xyz' } })
    const result = request(ctx)
    expect(result.operation).toBe('Query')
    expect(result.query.expression).toBe('id = :id')
    expect(result.query.expressionValues[':id']).toEqual({ S: 'xyz' })
  })
})

// ---------------------------------------------------------------------------
// queryByIdSort
// ---------------------------------------------------------------------------
describe('queryByIdSort', () => {
  const code = F.queryByIdSort('status')  // single positional arg
  const { request } = evalResolver(code)

  test('request queries by id and status', () => {
    const ctx = makeCtx({ args: { id: 'p1', status: 'active' } })
    const result = request(ctx)
    expect(result.operation).toBe('Query')
    expect(result.query.expression).toContain('id = :id')
    expect(result.query.expression).toContain('#status = :status')
    expect(result.query.expressionValues[':id']).toEqual({ S: 'p1' })
    expect(result.query.expressionValues[':status']).toEqual({ S: 'active' })
  })
})

// ---------------------------------------------------------------------------
// queryByIndex
// ---------------------------------------------------------------------------
describe('queryByIndex', () => {
  const { request, response } = evalResolver(F.queryByIndex('userId'))

  test('request queries by userId index', () => {
    const ctx = makeCtx({ args: { userId: 'u1' } })
    const result = request(ctx)
    expect(result.operation).toBe('Query')
    expect(result.index).toBe('userId')
    expect(result.query.expressionValues[':userId']).toEqual({ S: 'u1' })
  })

  test('response returns ctx.result', () => {
    const ctx = makeCtx({ result: [{ id: 'a' }] })
    expect(response(ctx)).toEqual([{ id: 'a' }])
  })
})

// ---------------------------------------------------------------------------
// listAllItems
// ---------------------------------------------------------------------------
describe('listAllItems', () => {
  const { request } = evalResolver(F.listAllItems)

  test('request returns Scan with default limit 50', () => {
    const ctx = makeCtx({ args: {} })
    const result = request(ctx)
    expect(result.operation).toBe('Scan')
    expect(result.limit).toBe(50)
    expect(result.nextToken).toBeNull()
  })

  test('request respects explicit limit', () => {
    const ctx = makeCtx({ args: { limit: 10 } })
    expect(request(ctx).limit).toBe(10)
  })
})

// ---------------------------------------------------------------------------
// queryByIndexSortFiltered — complex template, most important to test
// ---------------------------------------------------------------------------
describe('queryByIndexSortFiltered', () => {
  const code = F.queryByIndexSortFiltered('ownerId', 'ownerId', 'status')  // index, idField, sortField
  const { request, response } = evalResolver(code)

  test('query by idField only when sortField is absent', () => {
    const ctx = makeCtx({ args: { ownerId: 'u1' } })
    const result = request(ctx)
    expect(result.operation).toBe('Query')
    expect(result.query.expression).toBe('#ownerId = :ownerId')
    expect(result.filter).toBeUndefined()
    expect(result.index).toBe('ownerId')
    expect(result.limit).toBe(50)
  })

  test('query includes sortField when present', () => {
    const ctx = makeCtx({ args: { ownerId: 'u1', status: 'active' } })
    const result = request(ctx)
    expect(result.query.expression).toContain('#status = :status')
    expect(result.filter).toBeUndefined()
  })

  test('hideDeleted adds filter expression', () => {
    const ctx = makeCtx({ args: { ownerId: 'u1', hideDeleted: true } })
    const result = request(ctx)
    expect(result.filter).toBeDefined()
    expect(result.filter.expression).toContain('#deleted = :false')
  })

  test('array arg adds contains filter for each value', () => {
    const ctx = makeCtx({ args: { ownerId: 'u1', tags: ['a', 'b'] } })
    const result = request(ctx)
    expect(result.filter).toBeDefined()
    expect(result.filter.expression).toContain('contains(#tags')
  })

  test('string arg adds contains filter', () => {
    const ctx = makeCtx({ args: { ownerId: 'u1', name: 'Widget' } })
    const result = request(ctx)
    expect(result.filter).toBeDefined()
    expect(result.filter.expression).toContain('contains(#name, :name)')
  })

  test('scanIndexForward defaults to true', () => {
    const ctx = makeCtx({ args: { ownerId: 'u1' } })
    expect(request(ctx).scanIndexForward).toBe(true)
  })

  test('response returns result on success', () => {
    const ctx = makeCtx({ result: { items: [{ id: 'x' }] } })
    expect(response(ctx)).toEqual({ items: [{ id: 'x' }] })
  })
})

// ---------------------------------------------------------------------------
// putItem / deleteItem
// ---------------------------------------------------------------------------
describe('putItem', () => {
  const { request } = evalResolver(F.putItem)

  test('request returns PutItem with key and attributeValues', () => {
    const ctx = makeCtx({ args: { id: 'p1', name: 'Widget' } })
    const result = request(ctx)
    expect(result.operation).toBe('PutItem')
    expect(result.key.id).toEqual({ S: 'p1' })
    expect(result.attributeValues).toBeDefined()
  })
})

describe('deleteItem', () => {
  const { request } = evalResolver(F.deleteItem)

  test('request returns DeleteItem with string key', () => {
    const ctx = makeCtx({ args: { id: 'p1' } })
    const result = request(ctx)
    expect(result.operation).toBe('DeleteItem')
    expect(result.key.id).toEqual({ S: 'p1' })
  })
})

// ---------------------------------------------------------------------------
// Lambda invocations
// ---------------------------------------------------------------------------
describe('invokeCommandGenerator', () => {
  const { request, response } = evalResolver(F.invokeCommandGenerator('CreateProduct'))

  test('request sets operation Invoke with command CreateProduct', () => {
    const ctx = makeCtx({ args: { name: 'Widget' } })
    const result = request(ctx)
    expect(result.operation).toBe('Invoke')
    expect(result.payload.command).toBe('CreateProduct')
    expect(result.payload.arguments).toEqual({ name: 'Widget' })
  })

  test('request includes Cognito identity', () => {
    const ctx = makeCtx()
    const { payload } = request(ctx)
    expect(payload.identity.provider).toBe('Cognito')
    expect(payload.identity.username).toBe('testuser')
  })

  test('response returns ctx.result', () => {
    const ctx = makeCtx({ result: { msgId: '42' } })
    expect(response(ctx)).toEqual({ msgId: '42' })
  })
})

describe('invokeInboundTranslation', () => {
  const { request } = evalResolver(F.invokeInboundTranslation('importProduct'))

  test('request sets __inboundTranslation flag and fieldName', () => {
    const ctx = makeCtx({ args: { csv: 'data' } })
    const result = request(ctx)
    expect(result.operation).toBe('Invoke')
    expect(result.payload.__inboundTranslation).toBe(true)
    expect(result.payload.fieldName).toBe('importProduct')
    expect(result.payload.arguments).toEqual({ csv: 'data' })
  })
})

// ---------------------------------------------------------------------------
// Authorization
// ---------------------------------------------------------------------------
describe('authorizeIndexedAccess', () => {
  const code = F.authorizeIndexedAccess('resourceId', 'Admin')  // index, group
  const { request, response } = evalResolver(code)

  test('request does GetItem when user is in Admin group', () => {
    const ctx = makeCtx({
      args: { resourceId: 'r1' },
      identity: { username: 'alice', sub: 's1', sourceIp: [], claims: { 'cognito:groups': ['Admin'] } },
    })
    const result = request(ctx)
    expect(result.operation).toBe('GetItem')
    expect(result.key.id).toEqual({ S: 'r1' })
  })

  test('request earlyReturns when user is not in Admin group', () => {
    const ctx = makeCtx({
      args: { resourceId: 'r1' },
      identity: { username: 'bob', sub: 's2', sourceIp: [], claims: { 'cognito:groups': ['User'] } },
    })
    expect(() => request(ctx)).toThrow('earlyReturn')
  })

  test('response throws unauthorized when adminId does not match username', () => {
    const ctx = makeCtx({
      result: { adminId: 'alice' },
      identity: { username: 'bob', sub: 's2', sourceIp: [], claims: {} },
    })
    expect(() => response(ctx)).toThrow('Unauthorized')
  })

  test('response returns result when adminId matches username', () => {
    const ctx = makeCtx({
      result: { adminId: 'alice', data: 'secret' },
      identity: { username: 'alice', sub: 's1', sourceIp: [], claims: {} },
    })
    expect(response(ctx)).toEqual({ adminId: 'alice', data: 'secret' })
  })
})
