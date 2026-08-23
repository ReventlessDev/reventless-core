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
    ['getItemById', F.getItemById(undefined, undefined)],
    ['queryById', F.queryById],
    ['queryByIdSort(sortField)', F.queryByIdSort('status')],
    ['queryByIndex(index)', F.queryByIndex('userId')],
    ['queryByIndexDeletable(index)', F.queryByIndexDeletable('userId')],
    ['queryByIndexSort(index,idField,sortField)', F.queryByIndexSort('userId', 'userId', 'createdAt')],
    ['queryByIndexFiltered(index,idField)', F.queryByIndexFiltered('userId', 'userId')],
    ['queryByIndexSortFiltered(index,idField,sortField)', F.queryByIndexSortFiltered('userId', 'userId', undefined, 'status')],
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
  const { request, response } = evalResolver(F.getItemById(undefined, undefined))

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
// listAllItemsConnection — server-side filter/sort
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
      // The cursor encodes a real read window, not a positional index. The last row
      // closed this one, so it names the window that follows.
      expect(JSON.parse(util.base64Decode(r.pageInfo.endCursor)).t).toBe('next')
    })

    // The cursor the response emits must decode back to the DynamoDB nextToken the
    // request feeds to the next Scan.
    test('endCursor round-trips: response endCursor → request nextToken', () => {
      const page1 = response(makeCtx({
        args: {},
        result: { items: [{ id: 'a' }], nextToken: 'TOK1' },
      }))
      const req2 = request(makeCtx({ args: { after: page1.pageInfo.endCursor } }))
      expect(req2.nextToken).toBe('TOK1')
    })

    // `hasPreviousPage` reports what this door can SERVE, not what exists. This
    // cursor opens a new window at position 0, so the page before it lies in the
    // previous window — real, and unreachable, because a continuation token
    // cannot name the one before it. Claiming it is what drew a Prev button that
    // always errored.
    test('final page (nextToken null) closes the connection', () => {
      const after = util.base64Encode(JSON.stringify({ t: 'TOK1', n: -1 }))
      const r = response(makeCtx({
        args: { after },
        result: { items: [{ id: 'z' }], nextToken: null },
      }))
      expect(r.pageInfo.hasNextPage).toBe(false)
      expect(r.pageInfo.hasPreviousPage).toBe(false)
    })

    // A filtered Scan can return an empty page while nextToken is still set. The
    // boundary cursor must let the client resume instead of restarting page 1.
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

    // `before` is served by re-reading the window the cursor names and cutting
    // the page that ends at it. `last` is not: the last N rows of the list needs
    // the END of the list, which a forward-only cursor cannot reach.
    test('request rejects `last`, which needs the end of the list', () => {
      expect(() => request(makeCtx({ args: { last: 5 } }))).toThrow('last is not supported')
    })

    test('a backward page is the page that precedes it, exactly', () => {
      const items = Array.from({ length: 25 }, (_, i) => ({ id: 'r' + i }))
      const page1 = response(makeCtx({ args: { first: 10 }, result: { items, nextToken: null } }))
      const fwd = { args: { first: 10, after: page1.pageInfo.endCursor } }
      const page2 = response(makeCtx({ ...fwd, result: { items, nextToken: null } }))
      expect(page2.edges.map(e => e.node.id)).toEqual(items.slice(10, 20).map(i => i.id))

      const back = { args: { first: 10, before: page2.pageInfo.startCursor } }
      const prev = response(makeCtx({ ...back, result: { items, nextToken: null } }))
      expect(prev.edges.map(e => e.node.id)).toEqual(page1.edges.map(e => e.node.id))
      // Cut from ahead, so a next page provably exists — the one we came from.
      expect(prev.pageInfo.hasNextPage).toBe(true)
      expect(prev.pageInfo.hasPreviousPage).toBe(false)
    })

    // The read must reach `_upTo` rows into the window, not `first + from`, or the
    // backward slice comes back with its tail missing.
    test('a backward read examines the window as deep as the page it cuts', () => {
      const before = util.base64Encode(JSON.stringify({ t: null, n: 30 }))
      expect(request(makeCtx({ args: { first: 10, before } })).limit).toBe(30)
    })

    test('the window a backward cursor names is the one re-read', () => {
      const before = util.base64Encode(JSON.stringify({ t: 'W7', n: 30 }))
      expect(request(makeCtx({ args: { first: 10, before } })).nextToken).toBe('W7')
    })

    // The one page still out of reach, and the only case left refused.
    test('a previous page in an earlier window is refused, and says which limit', () => {
      const before = util.base64Encode(JSON.stringify({ t: 'W2', n: 0 }))
      expect(() => request(makeCtx({ args: { first: 10, before } }))).toThrow(
        'earlier read window',
      )
    })

    // At the very start there is no earlier window to be unable to name, so a
    // short backward page is served rather than refused.
    test('a backward page at the start of the first window is served, not refused', () => {
      const items = Array.from({ length: 10 }, (_, i) => ({ id: 'r' + i }))
      const before = util.base64Encode(JSON.stringify({ t: null, n: 3 }))
      const r = response(makeCtx({ args: { first: 10, before }, result: { items, nextToken: null } }))
      expect(r.edges.map(e => e.node.id)).toEqual(['r0', 'r1', 'r2'])
    })

    // Cursors minted before the read window existed named the following window.
    test('a pre-window { token, index } cursor still resumes', () => {
      const legacy = util.base64Encode(JSON.stringify({ token: 'TOK9', index: 3 }))
      const req = request(makeCtx({ args: { after: legacy } }))
      expect(req.nextToken).toBe('TOK9')
      const r = response(makeCtx({
        args: { after: legacy },
        result: { items: [{ id: 'a' }], nextToken: null },
      }))
      expect(r.edges).toHaveLength(1)
    })
  })

  // The defect a selective filter turns into a visibly broken list: DynamoDB
  // applies Limit before the FilterExpression, so reading `first` rows and
  // returning the survivors spreads one matching row over several pages, most of
  // them blank under a live Next button.
  describe('reads a window, serves a page', () => {
    const { request, response } = evalResolver(
      F.listAllItemsConnection('name', [], [], [], undefined, 'customerId', ['Admin']),
    )

    test('an unfiltered read examines exactly the page it serves', () => {
      const req = request(makeCtx({ args: { first: 25 }, identity: null }))
      expect(req.filter).toBeUndefined()
      expect(req.limit).toBe(25)
    })

    test('a filtered read examines a wider window than the page', () => {
      const req = request(makeCtx({ args: { first: 25 } }))
      expect(req.filter.expression).toBe('#owner = :owner')
      expect(req.limit).toBe(1000)
    })

    test('a caller asking for more than the window gets what it asked for', () => {
      expect(request(makeCtx({ args: { first: 5000 } })).limit).toBe(5000)
    })

    // The user-visible bug: one matching row must be one page, not three.
    test('the matches of an exhausted window are a single closed page', () => {
      const r = response(makeCtx({
        args: { first: 50 },
        result: { items: [{ id: 'mine' }], nextToken: null },
      }))
      expect(r.edges).toHaveLength(1)
      expect(r.pageInfo.hasNextPage).toBe(false)
    })

    test('a window holding more matches than the page pages within itself', () => {
      const items = [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }, { id: 'e' }]
      const page1 = response(makeCtx({
        args: { first: 2 },
        result: { items, nextToken: 'W2' },
      }))
      expect(page1.edges.map(e => e.node.id)).toEqual(['a', 'b'])
      expect(page1.pageInfo.hasNextPage).toBe(true)

      // Same window, resumed past the rows already served — not the next window.
      const req2 = request(makeCtx({ args: { first: 2, after: page1.pageInfo.endCursor } }))
      expect(req2.nextToken).toBeNull()
      const page2 = response(makeCtx({
        args: { first: 2, after: page1.pageInfo.endCursor },
        result: { items, nextToken: 'W2' },
      }))
      expect(page2.edges.map(e => e.node.id)).toEqual(['c', 'd'])

      // The row that closes the window hands the next request the window after it.
      const page3 = response(makeCtx({
        args: { first: 2, after: page2.pageInfo.endCursor },
        result: { items, nextToken: 'W2' },
      }))
      expect(page3.edges.map(e => e.node.id)).toEqual(['e'])
      expect(page3.pageInfo.hasNextPage).toBe(true)
      expect(
        request(makeCtx({ args: { first: 2, after: page3.pageInfo.endCursor } })).nextToken,
      ).toBe('W2')
    })

    // Without this the final row of a window resumes into a window with nothing
    // left in it, which is the blank page again one step later.
    test('the last row of a page that closes its window names the next window', () => {
      const r = response(makeCtx({
        args: { first: 2 },
        result: { items: [{ id: 'a' }, { id: 'b' }], nextToken: 'W2' },
      }))
      expect(JSON.parse(util.base64Decode(r.edges[1].cursor))).toEqual({ t: 'W2', n: -1 })
      expect(JSON.parse(util.base64Decode(r.edges[0].cursor))).toEqual({ t: null, n: 0 })
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
  // index, idField, ownerField, sortField — `ownerField` is optional but sits
  // ahead of `sortField`, so it has to be passed explicitly. Skipping it slid
  // the sort key into the owner slot and this file scoped the read by `status`
  // while asserting it did not, which is the failure mode a positional call
  // against a labelled-argument function always has.
  const code = F.queryByIndexSortFiltered('ownerId', 'ownerId', undefined, 'status')
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

  // The field this template is attached to has always been declared as returning
  // a Connection; handing back DynamoDB's `{items, nextToken}` satisfied no part
  // of that, so the door errored for every caller that selected `edges`.
  test('response returns a Relay connection', () => {
    const ctx = makeCtx({ result: { items: [{ id: 'x' }], nextToken: null } })
    const out = response(ctx)
    expect(out.edges.map(e => e.node)).toEqual([{ id: 'x' }])
    expect(out.pageInfo.hasNextPage).toBe(false)
  })

  test('reports a further page when DynamoDB hands back a token', () => {
    const ctx = makeCtx({ result: { items: [{ id: 'x' }], nextToken: 'TOK' } })
    expect(response(ctx).pageInfo.hasNextPage).toBe(true)
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
// The one read path with no Lambda in it — the predicate is generated JS that
// AppSync runs directly, sharing no code with the paths the ReScript suites
// cover. Evaluating the emitted source is the strongest check short of a deploy.
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

  // ── The same identities, once the scope has an index to read ──────────────
  //
  // The predicate moves from the FilterExpression to a key condition, so who is
  // narrowed and who is not now selects a different PHYSICAL READ. The defect
  // class this guards against was invisible precisely because each path was
  // individually correct — so the identity table runs over both, rather than a
  // parallel suite growing beside it.
  //
  // (labelField, filterFields, rangeFields, sortFields, requireAttribute,
  //  ownerField, elevatedGroups, retiredField, retiredValues,
  //  ownerIndex, ownerIndexSortField)
  const indexed = () =>
    evalResolver(
      F.listAllItemsConnection(
        'name', ['status'], [], [], undefined, 'customerId', ['Admin'],
        undefined, undefined, '_owner', 'id',
      ),
    )

  const identities = [
    ['a plain caller', asUser('cust-a'), 'Query'],
    ['a caller in an elevated group', asUser('ops-1', ['Admin']), 'Scan'],
    ['an IAM-shaped identity with no sub', { userArn: 'arn:aws:sts::1:x', username: 'Ing' }, 'Scan'],
    ['a wholly absent identity', null, 'Scan'],
  ]

  test.each(identities)('%s reads through the operation its scope implies', (_, identity, op) => {
    const { request } = indexed()
    expect(request(makeCtx({ args: {}, identity })).operation).toBe(op)
  })

  test('a scoped caller is keyed on their own id, not filtered on it', () => {
    const { request } = indexed()
    const r = request(makeCtx({ args: {}, identity: asUser('cust-a') }))
    expect(r.index).toBe('_owner')
    expect(r.query.expression).toBe('#owner = :owner')
    expect(r.query.expressionNames['#owner']).toBe('customerId')
    expect(r.query.expressionValues[':owner']).toEqual({ S: 'cust-a' })
    // The whole point: no owner clause survives anywhere in the filter. A copy
    // left there would be a second, redundant predicate — and an expressionName
    // the filter no longer references is a ValidationException.
    expect(r.filter).toBeUndefined()
  })

  // The elevated read is the one that must not have changed: it is the same
  // request the unindexed resolver builds, argument for argument.
  test.each([
    ['an elevated caller', asUser('ops-1', ['Admin'])],
    ['an IAM service caller', { userArn: 'arn:aws:sts::1:x', username: 'Ing' }],
  ])("%s's read is unchanged by the index existing", (_, identity) => {
    const before = evalResolver(
      F.listAllItemsConnection('name', ['status'], [], [], undefined, 'customerId', ['Admin']),
    ).request(makeCtx({ args: { first: 20, filter: { statusEq: 'Placed' } }, identity }))
    const after = indexed().request(
      makeCtx({ args: { first: 20, filter: { statusEq: 'Placed' } }, identity }),
    )
    expect(after).toEqual(before)
  })

  // The read window exists because a FilterExpression cuts rows AFTER `Limit`.
  // A key condition does not, so a scoped caller with no filter of their own
  // examines exactly the page they asked for — the arithmetic the window was
  // hiding, gone rather than papered over.
  test('a scoped caller with no filter examines exactly the page', () => {
    const { request } = indexed()
    expect(request(makeCtx({ args: { first: 25 }, identity: asUser('cust-a') })).limit).toBe(25)
  })

  test("a scoped caller's own filter still widens the window", () => {
    const { request } = indexed()
    const r = request(
      makeCtx({ args: { first: 25, filter: { statusEq: 'Placed' } }, identity: asUser('cust-a') }),
    )
    expect(r.limit).toBe(1000)
    expect(r.filter.expression).toBe('#status = :statusEq')
  })

  // Both branches are reachable by the SAME caller across requests — an active
  // role switch mid-pagination flips `_exempt`. A `nextToken` continues the
  // operation that minted it, so replaying one on the other branch would answer
  // a different question in silence.
  describe('the cursor path tag', () => {
    const { request, response } = indexed()
    const pageFor = identity =>
      response(makeCtx({
        args: {},
        identity,
        result: { items: [{ id: 'a' }], nextToken: 'TOK' },
      })).pageInfo.endCursor

    test('a Scan cursor replayed on the Query branch is refused', () => {
      const scanCursor = pageFor(asUser('ops-1', ['Admin']))
      expect(() =>
        request(makeCtx({ args: { after: scanCursor }, identity: asUser('cust-a') })),
      ).toThrow('different read of this list')
    })

    test('a Query cursor replayed on the Scan branch is refused', () => {
      const queryCursor = pageFor(asUser('cust-a'))
      expect(() =>
        request(makeCtx({ args: { after: queryCursor }, identity: asUser('ops-1', ['Admin']) })),
      ).toThrow('different read of this list')
    })

    test('each branch resumes its own cursor', () => {
      expect(
        request(makeCtx({ args: { after: pageFor(asUser('cust-a')) }, identity: asUser('cust-a') }))
          .nextToken,
      ).toBe('TOK')
      const ops = asUser('ops-1', ['Admin'])
      expect(request(makeCtx({ args: { after: pageFor(ops) }, identity: ops })).nextToken).toBe('TOK')
    })

    // Cursors minted before the tag existed all came off a Scan, and the callers
    // holding one are the exempt callers whose read did not change.
    test('an untagged cursor still resumes the Scan branch', () => {
      const legacy = util.base64Encode(JSON.stringify({ t: 'TOK9', n: 2 }))
      const ops = asUser('ops-1', ['Admin'])
      expect(request(makeCtx({ args: { after: legacy }, identity: ops })).nextToken).toBe('TOK9')
    })
  })

  // Ordering on the index's own sort key is `ScanIndexForward`'s job across the
  // caller's whole partition. Re-sorting the page in JS afterwards is the one
  // way to BREAK that order — a sort over a page is not a sort over the rows.
  describe('orderBy on the index sort key', () => {
    const sorted = () =>
      evalResolver(
        F.listAllItemsConnection(
          'name', [], [], ['id', 'placedAt'], undefined, 'customerId', ['Admin'],
          undefined, undefined, '_owner', 'id',
        ),
      )
    const items = [{ id: 'c' }, { id: 'a' }, { id: 'b' }]
    const scoped = asUser('cust-a')

    test('DESC flips scanIndexForward instead of reversing a page', () => {
      const { request } = sorted()
      const args = { orderBy: { field: 'id', direction: 'DESC' } }
      expect(request(makeCtx({ args, identity: scoped })).scanIndexForward).toBe(false)
      expect(
        request(makeCtx({ args: { orderBy: { field: 'id', direction: 'ASC' } }, identity: scoped }))
          .scanIndexForward,
      ).toBe(true)
    })

    test('the page DynamoDB ordered is handed back untouched', () => {
      const { response } = sorted()
      const r = response(makeCtx({
        args: { orderBy: { field: 'id', direction: 'ASC' } },
        identity: scoped,
        result: { items, nextToken: null },
      }))
      expect(r.edges.map(e => e.node.id)).toEqual(['c', 'a', 'b'])
    })

    test('any other sort field still sorts in JS', () => {
      const { response } = sorted()
      const r = response(makeCtx({
        args: { orderBy: { field: 'placedAt', direction: 'ASC' } },
        identity: scoped,
        result: { items: [{ placedAt: 'z' }, { placedAt: 'a' }], nextToken: null },
      }))
      expect(r.edges.map(e => e.node.placedAt)).toEqual(['a', 'z'])
    })

    // The exempt caller Scans, which has no ordering of its own, so the per-page
    // sort is still the only order they get.
    test('an exempt caller keeps the per-page sort on the same field', () => {
      const { response } = sorted()
      const r = response(makeCtx({
        args: { orderBy: { field: 'id', direction: 'ASC' } },
        identity: asUser('ops-1', ['Admin']),
        result: { items, nextToken: null },
      }))
      expect(r.edges.map(e => e.node.id)).toEqual(['a', 'b', 'c'])
    })
  })

  // Backward paging works the same way on both branches, and for the same reason:
  // it re-reads the window the cursor names and cuts the page ending at it, which
  // is operation-agnostic. `last` stays refused on both — it needs the end of the
  // list, which neither a Scan nor this Query's cursor can reach.
  test.each([['scoped', asUser('cust-a')], ['exempt', asUser('ops-1', ['Admin'])]])(
    'a %s caller is still refused `last`',
    (_, identity) => {
      const { request } = indexed()
      expect(() => request(makeCtx({ args: { last: 5 }, identity }))).toThrow(
        'last is not supported',
      )
    },
  )

  // The path tag has to survive the direction change: a backward cursor still
  // names the read that minted it, and replaying it on the other branch is the
  // same mistake as replaying a forward one.
  test('a backward cursor is path-checked like a forward one', () => {
    const { request, response } = indexed()
    const scopedPage = response(makeCtx({
      args: { first: 10 },
      identity: asUser('cust-a'),
      result: { items: Array.from({ length: 10 }, (_, i) => ({ id: 'r' + i })), nextToken: null },
    }))
    expect(() =>
      request(makeCtx({
        args: { first: 10, before: scopedPage.pageInfo.endCursor },
        identity: asUser('ops-1', ['Admin']),
      })),
    ).toThrow('different read of this list')
  })
})

// ---------------------------------------------------------------------------
// By-key reads — owner scoping
// ---------------------------------------------------------------------------
// The list resolver carried the predicate while these did not, so a caller
// narrowed to their own rows could still read any row they could name. The guard
// belongs in the response — GetItem has no FilterExpression — and answers null.
describe('getItemById / queryByIdSort — owner scoping', () => {
  const asUser = (sub, groups = []) => ({
    username: sub,
    sub,
    sourceIp: [],
    claims: { 'cognito:groups': groups },
  })
  const row = { id: 'ord-1', customerId: 'cust-a', total: 10 }

  const getScoped = () => evalResolver(F.getItemById('customerId', ['Admin']))
  const sortScoped = () => evalResolver(F.queryByIdSort('status', 'customerId', ['Admin']))

  test('an owner reads their own row', () => {
    const { response } = getScoped()
    expect(response(makeCtx({ result: row, identity: asUser('cust-a') }))).toEqual(row)
  })

  test('a foreign row reads as null, not as an error', () => {
    const { response } = getScoped()
    expect(response(makeCtx({ result: row, identity: asUser('cust-b') }))).toBeNull()
  })

  test('an elevated caller reads any row', () => {
    const { response } = getScoped()
    expect(response(makeCtx({ result: row, identity: asUser('ops-1', ['Admin']) }))).toEqual(row)
  })

  test('an IAM-shaped identity with no sub is exempt, not compared against undefined', () => {
    const { response } = getScoped()
    const iam = { username: 'svc', userArn: 'arn:aws:iam::1:role/r', sourceIp: [] }
    expect(response(makeCtx({ result: row, identity: iam }))).toEqual(row)
  })

  test('a wholly absent identity is exempt rather than a crash', () => {
    const { response } = getScoped()
    expect(response(makeCtx({ result: row, identity: null }))).toEqual(row)
  })

  test('a missing row stays null and does not fall into the ownership branch', () => {
    const { response } = getScoped()
    expect(response(makeCtx({ result: null, identity: asUser('cust-b') }))).toBeNull()
  })

  test('a view with no owner field is never scoped', () => {
    const { response } = evalResolver(F.getItemById(undefined, []))
    expect(response(makeCtx({ result: row, identity: asUser('cust-b') }))).toEqual(row)
  })

  test('queryByIdSort narrows its first row the same way', () => {
    const { response } = sortScoped()
    const ctxFor = sub => makeCtx({ result: { items: [row] }, identity: asUser(sub) })
    expect(response(ctxFor('cust-a'))).toEqual(row)
    expect(response(ctxFor('cust-b'))).toBeNull()
  })

  test('queryItemsWithSortConditions scopes in the REQUEST, so the page is cut after narrowing', () => {
    const { request } = evalResolver(
      F.queryItemsWithSortConditions('createdAt', 'customerId', ['Admin']),
    )
    const scoped = request(makeCtx({ args: { id: 'ord-1' }, identity: asUser('cust-a') }))
    expect(scoped.filter.expression).toBe('#owner = :owner')
    expect(scoped.filter.expressionValues[':owner']).toEqual({ S: 'cust-a' })
    const elevated = request(
      makeCtx({ args: { id: 'ord-1' }, identity: asUser('ops-1', ['Admin']) }),
    )
    expect(elevated.filter).toBeUndefined()
  })
})
