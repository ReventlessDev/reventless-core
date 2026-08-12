import { evalResolver, makeCtx } from './resolverTestHelper.mjs'
import { util } from './__mocks__/appsync-utils.mjs'
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
// listAllItemsConnection — Phase 3 server-side filter/sort
// ---------------------------------------------------------------------------
describe('listAllItemsConnection', () => {
  describe('default (no capability args)', () => {
    const { request, response } = evalResolver(F.listAllItemsConnection('name'))

    test('request returns Scan without filter when no args', () => {
      const ctx = makeCtx({ args: {} })
      const result = request(ctx)
      expect(result.operation).toBe('Scan')
      expect(result.limit).toBe(50)
      expect(result.nextToken).toBeNull()
      expect(result.filter).toBeUndefined()
    })

    test('request adds search clause as contains(labelField)', () => {
      const ctx = makeCtx({ args: { filter: { search: 'Wid' } } })
      const result = request(ctx)
      expect(result.filter.expression).toBe('contains(#label, :search)')
      expect(result.filter.expressionNames['#label']).toBe('name')
    })

    test('request adds searchPrefix as begins_with(labelField)', () => {
      const ctx = makeCtx({ args: { filter: { searchPrefix: 'Wid' } } })
      const result = request(ctx)
      expect(result.filter.expression).toBe('begins_with(#label, :searchPrefix)')
    })

    test('request adds ids as IN clause', () => {
      const ctx = makeCtx({ args: { filter: { ids: ['a', 'b'] } } })
      const result = request(ctx)
      expect(result.filter.expression).toBe('#id IN (:id0, :id1)')
      expect(result.filter.expressionValues[':id0']).toEqual({ S: 'a' })
    })

    test('response returns edges + pageInfo carrying the DynamoDB token cursor', () => {
      const ctx = makeCtx({
        args: {},
        result: { items: [{ id: 'a' }, { id: 'b' }], nextToken: 'next' },
      })
      const r = response(ctx)
      expect(r.edges).toHaveLength(2)
      expect(r.edges[0].node).toEqual({ id: 'a' })
      expect(r.pageInfo.hasNextPage).toBe(true)
      expect(r.pageInfo.hasPreviousPage).toBe(false)
      // Fix 1: the cursor encodes the real nextToken, not a positional index.
      expect(JSON.parse(util.base64Decode(r.pageInfo.endCursor)).token).toBe('next')
    })

    // Fix 1 (docs/plans/done/aws-scan-connection-cursor-roundtrip.md): the cursor the
    // response emits must decode back to the exact DynamoDB nextToken the request feeds
    // to the next Scan. This is the round-trip that failed before the fix.
    test('endCursor round-trips: response endCursor → request nextToken', () => {
      const page1 = response(makeCtx({
        args: {},
        result: { items: [{ id: 'a' }], nextToken: 'TOK1' },
      }))
      const req2 = request(makeCtx({ args: { after: page1.pageInfo.endCursor } }))
      expect(req2.nextToken).toBe('TOK1')
    })

    test('final page (nextToken null) closes the connection', () => {
      const r = response(makeCtx({
        args: { after: 'x' },
        result: { items: [{ id: 'z' }], nextToken: null },
      }))
      expect(r.pageInfo.hasNextPage).toBe(false)
      expect(r.pageInfo.hasPreviousPage).toBe(true)
    })

    // Fix 3: a filtered Scan can return an empty page while nextToken is still set.
    // The boundary cursor must let the client resume instead of restarting page 1.
    test('empty-but-continuable page yields a resumable boundary cursor', () => {
      const empty = response(makeCtx({
        args: {},
        result: { items: [], nextToken: 'TOK2' },
      }))
      expect(empty.edges).toHaveLength(0)
      expect(empty.pageInfo.hasNextPage).toBe(true)
      expect(empty.pageInfo.endCursor).not.toBeNull()
      const req = request(makeCtx({ args: { after: empty.pageInfo.endCursor } }))
      expect(req.nextToken).toBe('TOK2')
    })

    test('empty final page (nextToken null) has a null boundary and stops', () => {
      const r = response(makeCtx({ args: {}, result: { items: [], nextToken: null } }))
      expect(r.pageInfo.endCursor).toBeNull()
      expect(r.pageInfo.hasNextPage).toBe(false)
    })

    // Fix 2: Scan cannot page backward; last/before must error, not mislead.
    test('request rejects backward pagination (before)', () => {
      expect(() => request(makeCtx({ args: { before: 'x' } }))).toThrow(
        'Backward pagination',
      )
    })

    test('request rejects backward pagination (last)', () => {
      expect(() => request(makeCtx({ args: { last: 5 } }))).toThrow('Backward pagination')
    })
  })

  describe('with filterFields (per-field Eq)', () => {
    const code = F.listAllItemsConnection('name', ['status', 'ownerId'])
    const { request } = evalResolver(code)

    test('request adds status = :statusEq when filter.statusEq is set', () => {
      const ctx = makeCtx({ args: { filter: { statusEq: 'active' } } })
      const result = request(ctx)
      expect(result.filter.expression).toBe('#status = :statusEq')
      expect(result.filter.expressionNames['#status']).toBe('status')
      expect(result.filter.expressionValues[':statusEq']).toEqual({ S: 'active' })
    })

    test('request combines multiple per-field eq with AND', () => {
      const ctx = makeCtx({
        args: { filter: { statusEq: 'active', ownerIdEq: 'u1' } },
      })
      const result = request(ctx)
      expect(result.filter.expression).toBe('#status = :statusEq AND #ownerId = :ownerIdEq')
    })

    test('request omits clause when value is null/undefined/empty', () => {
      const ctx = makeCtx({ args: { filter: { statusEq: '', ownerIdEq: null } } })
      const result = request(ctx)
      expect(result.filter).toBeUndefined()
    })

    test('request combines per-field eq with legacy search', () => {
      const ctx = makeCtx({
        args: { filter: { search: 'Wid', statusEq: 'active' } },
      })
      const result = request(ctx)
      expect(result.filter.expression).toBe(
        'contains(#label, :search) AND #status = :statusEq',
      )
    })
  })

  describe('with rangeFields (per-field From/To)', () => {
    const code = F.listAllItemsConnection('name', ['createdAt'], ['createdAt'])
    const { request } = evalResolver(code)

    test('request adds >= clause for From', () => {
      const ctx = makeCtx({ args: { filter: { createdAtFrom: '2026-01-01' } } })
      const result = request(ctx)
      expect(result.filter.expression).toBe('#createdAt >= :createdAtFrom')
    })

    test('request adds <= clause for To', () => {
      const ctx = makeCtx({ args: { filter: { createdAtTo: '2026-12-31' } } })
      const result = request(ctx)
      expect(result.filter.expression).toBe('#createdAt <= :createdAtTo')
    })

    test('request combines From + To with AND', () => {
      const ctx = makeCtx({
        args: {
          filter: { createdAtFrom: '2026-01-01', createdAtTo: '2026-12-31' },
        },
      })
      const result = request(ctx)
      expect(result.filter.expression).toBe(
        '#createdAt >= :createdAtFrom AND #createdAt <= :createdAtTo',
      )
    })

    test('eq + range can compose on the same field', () => {
      const ctx = makeCtx({
        args: { filter: { createdAtEq: '2026-06-15', createdAtFrom: '2026-01-01' } },
      })
      const result = request(ctx)
      expect(result.filter.expression).toBe(
        '#createdAt = :createdAtEq AND #createdAt >= :createdAtFrom',
      )
    })
  })

  describe('with sortFields (per-page sort)', () => {
    const code = F.listAllItemsConnection('name', [], [], ['name', 'createdAt'])
    const { response } = evalResolver(code)

    test('response sorts items ASC by orderBy.field', () => {
      const ctx = makeCtx({
        args: { orderBy: { field: 'name', direction: 'ASC' } },
        result: {
          items: [{ name: 'C' }, { name: 'A' }, { name: 'B' }],
          nextToken: null,
        },
      })
      const r = response(ctx)
      expect(r.edges.map(e => e.node.name)).toEqual(['A', 'B', 'C'])
    })

    test('response sorts items DESC by orderBy.field', () => {
      const ctx = makeCtx({
        args: { orderBy: { field: 'name', direction: 'DESC' } },
        result: {
          items: [{ name: 'A' }, { name: 'C' }, { name: 'B' }],
          nextToken: null,
        },
      })
      const r = response(ctx)
      expect(r.edges.map(e => e.node.name)).toEqual(['C', 'B', 'A'])
    })

    test('response leaves order untouched when orderBy.field is not in sortFields', () => {
      const ctx = makeCtx({
        args: { orderBy: { field: 'unknown', direction: 'ASC' } },
        result: { items: [{ name: 'C' }, { name: 'A' }], nextToken: null },
      })
      const r = response(ctx)
      expect(r.edges.map(e => e.node.name)).toEqual(['C', 'A'])
    })

    test('response leaves order untouched when no orderBy supplied', () => {
      const ctx = makeCtx({
        args: {},
        result: { items: [{ name: 'C' }, { name: 'A' }], nextToken: null },
      })
      const r = response(ctx)
      expect(r.edges.map(e => e.node.name)).toEqual(['C', 'A'])
    })

    test('response sorts null/undefined values to the end', () => {
      const ctx = makeCtx({
        args: { orderBy: { field: 'name', direction: 'ASC' } },
        result: {
          items: [{ name: 'B' }, { name: null }, { name: 'A' }],
          nextToken: null,
        },
      })
      const r = response(ctx)
      expect(r.edges.map(e => e.node.name)).toEqual(['A', 'B', null])
    })

    test('response keeps nulls at the end under DESC direction', () => {
      const ctx = makeCtx({
        args: { orderBy: { field: 'name', direction: 'DESC' } },
        result: {
          items: [{ name: 'A' }, { name: null }, { name: 'B' }],
          nextToken: null,
        },
      })
      const r = response(ctx)
      expect(r.edges.map(e => e.node.name)).toEqual(['B', 'A', null])
    })

    test('response sorts numeric fields in numeric (not lexicographic) order', () => {
      // The schwartzian transform pads numbers so '10' sorts after '2', not before.
      const code = F.listAllItemsConnection('name', [], [], ['count'])
      const { response: numResp } = evalResolver(code)
      const ctx = makeCtx({
        args: { orderBy: { field: 'count', direction: 'ASC' } },
        result: {
          items: [{ count: 10 }, { count: 2 }, { count: 100 }],
          nextToken: null,
        },
      })
      const r = numResp(ctx)
      expect(r.edges.map(e => e.node.count)).toEqual([2, 10, 100])
    })
  })

  describe('combined filter + sort', () => {
    const code = F.listAllItemsConnection('name', ['status'], [], ['name'])
    const { request, response } = evalResolver(code)

    test('request emits filter; response sorts page', () => {
      const reqCtx = makeCtx({
        args: {
          filter: { statusEq: 'active' },
          orderBy: { field: 'name', direction: 'ASC' },
        },
      })
      expect(request(reqCtx).filter.expression).toBe('#status = :statusEq')
      const respCtx = makeCtx({
        args: { orderBy: { field: 'name', direction: 'ASC' } },
        result: { items: [{ name: 'B' }, { name: 'A' }], nextToken: null },
      })
      expect(response(respCtx).edges.map(e => e.node.name)).toEqual(['A', 'B'])
    })
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

  test('request emits IAM identity when ctx.identity has userArn but no sub', () => {
    const ctx = makeCtx({
      identity: {
        userArn: 'arn:aws:iam::123:role/SyncRole',
        accountId: '123',
        username: 'AROAEXAMPLE:caller',
        sourceIp: ['10.0.0.1'],
      },
    })
    const { payload } = request(ctx)
    expect(payload.identity.provider).toBe('IAM')
    expect(payload.identity.userArn).toBe('arn:aws:iam::123:role/SyncRole')
    expect(payload.identity.accountId).toBe('123')
    expect(payload.identity.username).toBe('AROAEXAMPLE:caller')
    expect(payload.meta.ip).toEqual(['10.0.0.1'])
    expect(payload.meta.user).toBe('AROAEXAMPLE:caller')
  })

  test('request emits null identity when ctx.identity is null (API_KEY)', () => {
    const ctx = makeCtx({ identity: null })
    const { payload } = request(ctx)
    expect(payload.identity).toBeNull()
    expect(payload.meta.ip).toBeNull()
    expect(payload.meta.user).toBeNull()
    expect(payload.command).toBe('CreateProduct')
  })

  test('response returns ctx.result', () => {
    const ctx = makeCtx({ result: { msgId: '42' } })
    expect(response(ctx)).toEqual({ msgId: '42' })
  })
})

describe('invokeDcbMutation', () => {
  const { request } = evalResolver(F.invokeDcbMutation('Product'))

  test('request emits Cognito identity by default', () => {
    const ctx = makeCtx({ args: { sku: 'X1' } })
    const { payload } = request(ctx)
    expect(payload.command).toBe('Product')
    expect(payload.arguments).toEqual({ sku: 'X1' })
    expect(payload.identity.provider).toBe('Cognito')
  })

  test('request emits IAM identity when ctx.identity has userArn but no sub', () => {
    const ctx = makeCtx({
      identity: { userArn: 'arn:aws:iam::123:role/Sync', accountId: '123' },
    })
    const { payload } = request(ctx)
    expect(payload.identity.provider).toBe('IAM')
    expect(payload.identity.userArn).toBe('arn:aws:iam::123:role/Sync')
  })

  test('request emits null identity when ctx.identity is null', () => {
    const ctx = makeCtx({ identity: null })
    const { payload } = request(ctx)
    expect(payload.identity).toBeNull()
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

// ---------------------------------------------------------------------------
// listAllItemsConnection — @owner scoping
// ---------------------------------------------------------------------------
// This is the one read path with no Lambda in it: the predicate lives in
// generated JS that AppSync runs directly, so it shares no code with the three
// paths the ReScript suites cover. Evaluating the emitted source here is the
// strongest check available short of a deployed stack, and the only one that
// can catch an APPSYNC_JS-hostile construct or a mis-ordered branch.
describe('listAllItemsConnection — owner scoping', () => {
  // (labelField, filterFields, rangeFields, sortFields, requireAttribute,
  //  ownerField, elevatedGroups)
  const scoped = () =>
    evalResolver(
      F.listAllItemsConnection('name', ['status'], [], [], undefined, 'customerId', ['Admin']),
    )

  const asUser = (sub, groups = []) => ({
    username: sub,
    sub,
    sourceIp: [],
    claims: { 'cognito:groups': groups },
  })

  test('a plain caller is narrowed to their own rows', () => {
    const { request } = scoped()
    const r = request(makeCtx({ args: {}, identity: asUser('cust-a') }))
    expect(r.filter.expression).toBe('#owner = :owner')
    expect(r.filter.expressionNames['#owner']).toBe('customerId')
    expect(r.filter.expressionValues[':owner']).toEqual({ S: 'cust-a' })
  })

  test('the owner clause is ANDed with a client filter, not replaced by it', () => {
    const { request } = scoped()
    const r = request(
      makeCtx({ args: { filter: { statusEq: 'Placed' } }, identity: asUser('cust-a') }),
    )
    expect(r.filter.expression).toBe('#status = :statusEq AND #owner = :owner')
  })

  // The caller cannot address the channel the scope arrives on: naming the owner
  // field in their own filter must not overwrite the value the resolver derived.
  test('a client filter naming the owner field cannot displace the scope', () => {
    const { request } = scoped()
    const r = request(
      makeCtx({ args: { filter: { customerIdEq: 'cust-b' } }, identity: asUser('cust-a') }),
    )
    expect(r.filter.expressionValues[':owner']).toEqual({ S: 'cust-a' })
    expect(r.filter.expression).toContain('#owner = :owner')
  })

  test('a caller in an elevated group is not narrowed', () => {
    const { request } = scoped()
    const r = request(makeCtx({ args: {}, identity: asUser('ops-1', ['Admin']) }))
    expect(r.filter).toBeUndefined()
  })

  // The IAM service caller: present, but with no `sub` and no groups. Ordering
  // the group test first would classify it as non-elevated and then filter on
  // `undefined`, so every service read would return nothing.
  test('an IAM-shaped identity with no sub is exempt, not filtered on undefined', () => {
    const { request } = scoped()
    const r = request(
      makeCtx({
        args: {},
        identity: { userArn: 'arn:aws:sts::1:assumed-role/Ingester', username: 'Ingester' },
      }),
    )
    expect(r.filter).toBeUndefined()
  })

  test('a wholly absent identity is exempt rather than a crash', () => {
    const { request } = scoped()
    expect(() => request(makeCtx({ args: {}, identity: null }))).not.toThrow()
    expect(request(makeCtx({ args: {}, identity: null })).filter).toBeUndefined()
  })

  // The control: without an owner field nothing changes for anyone, which is
  // what keeps this from silently altering every existing read model.
  test('a view with no owner field is never scoped', () => {
    const { request } = evalResolver(F.listAllItemsConnection('name'))
    const r = request(makeCtx({ args: {}, identity: asUser('cust-a') }))
    expect(r.filter).toBeUndefined()
  })

  test('with no elevated groups configured, an Admin is still narrowed', () => {
    const { request } = evalResolver(
      F.listAllItemsConnection('name', [], [], [], undefined, 'customerId', []),
    )
    const r = request(makeCtx({ args: {}, identity: asUser('ops-1', ['Admin']) }))
    expect(r.filter.expressionValues[':owner']).toEqual({ S: 'ops-1' })
  })
})
