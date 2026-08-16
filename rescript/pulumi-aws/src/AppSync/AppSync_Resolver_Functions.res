/** AppSync JS resolver code for the APPSYNC_JS runtime.

    Each value is a Pulumi.Input.t<string> containing a complete ES module with
    exported `request` and `response` functions, ready to be passed as the `code`
    field of AppSync_Resolver.makeUnitJsResolver / makePipelineJsResolver.
*/

// ---------------------------------------------------------------------------
// Shared response snippets (inlined into each resolver's template literal)
// ---------------------------------------------------------------------------

let resultResponseCode = `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}`

let firstResultResponseCode = `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result.items[0] ?? null;
}`

let resultListResponseCode = `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result.items;
}`

let importUtil = `import { util } from '@aws-appsync/utils';`

/**
The caller-is-exempt test, emitted into a resolver's response.

Mirrors `Reventless.OwnerScope.resolve` — the same branch order for the same
reason the list predicate gives: an IAM-signed service caller has no `sub`
because it is inside the trust boundary, not because it is anonymous, so the
provider question is answered before the identity one.

In the RESPONSE rather than the request, because a `GetItem` has no
FilterExpression to carry a predicate: the row is fetched by key and the
decision is made on what came back. A `Query` could filter server-side, and
deliberately does not — a single-row read that filtered in one place and
guarded in another would have two implementations of one rule, and the cheaper
one is the one nobody would remember to change.
*/
let ownerGuardPreamble = (~ownerField: string, ~elevatedGroups: array<string>) => {
  let elevatedLiteral = elevatedGroups->Array.map(g => `'${g}'`)->Array.join(", ")
  `
  const _id = ctx.identity;
  const _sub = _id == null ? null : _id.sub;
  const _groups = (_id != null && _id.claims != null && _id.claims['cognito:groups']) || [];
  const _elevated = [${elevatedLiteral}];
  const _exempt = _sub == null || _groups.some(g => _elevated.indexOf(g) >= 0);
  const _owns = (row) => row == null || _exempt || row['${ownerField}'] === _sub;`
}

/**
A by-key read's response, refusing a row the caller does not own.

**Null, not an error** — which is the opposite of what a first reading suggests,
since "you may not read this" and "there is nothing here" are different answers
and only one of them is true. Two things settle it. The in-process platform
already answers `null` here, and a rule enforced differently per transport is
the failure mode owner scoping exists to avoid. And an error would confirm the
row exists to a caller who may not read it, which is a worse leak than the
ambiguity it removes.
*/
let ownerScopedResultResponse = (~ownerField: option<string>, ~elevatedGroups: array<string>) =>
  switch ownerField {
  | None => resultResponseCode
  | Some(field) =>
    `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  // ── owner scoping (generated) ──${ownerGuardPreamble(~ownerField=field, ~elevatedGroups)}
  return _owns(ctx.result) ? ctx.result : null;
}`
  }

/** The `queryByIdSort` counterpart — same rule, over the first row of a Query. */
let ownerScopedFirstResultResponse = (~ownerField: option<string>, ~elevatedGroups: array<string>) =>
  switch ownerField {
  | None => firstResultResponseCode
  | Some(field) =>
    `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  // ── owner scoping (generated) ──${ownerGuardPreamble(~ownerField=field, ~elevatedGroups)}
  const _row = ctx.result.items[0] ?? null;
  return _owns(_row) ? _row : null;
}`
  }

// ---------------------------------------------------------------------------
// Pipeline resolver pass-through (no before/after processing)
// ---------------------------------------------------------------------------

/** Pipeline resolver code with no pre-processing and a standard error-check response. */
let pipelinePassThrough =
  `${importUtil}
export function request(ctx) { return {}; }
${resultResponseCode}
`->Pulumi.Input.make

// ---------------------------------------------------------------------------
// Relay Node resolver — pipeline functions for node(id: ID!) query
// ---------------------------------------------------------------------------

/** Pipeline function (NONE datasource): decodes global ID and stashes typeName + localId. */
let nodeDecodeGlobalId =
  `${importUtil}
export function request(ctx) {
  const globalId = ctx.args.id;
  try {
    const decoded = util.base64Decode(globalId);
    const colonIdx = decoded.indexOf(':');
    if (colonIdx > 0) {
      ctx.stash.typeName = decoded.substring(0, colonIdx);
      ctx.stash.localId = decoded.substring(colonIdx + 1);
    }
  } catch (e) {
    ctx.stash.typeName = null;
    ctx.stash.localId = null;
  }
  return { payload: null };
}
export function response(ctx) {
  return ctx.stash;
}
`->Pulumi.Input.make

/** Pipeline function (DynamoDB datasource): fetches item if typeName matches, skips otherwise.
    Generated per entity type at deploy time. */
let nodeGetItemForType = (~typeName: string): Pulumi.Input.t<string> =>
  `${importUtil}
export function request(ctx) {
  if (ctx.stash.typeName !== '${typeName}') return runtime.earlyReturn(ctx.prev.result);
  return {
    operation: 'GetItem',
    key: { id: util.dynamodb.toDynamoDB(ctx.stash.localId) }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  if (!ctx.result) return null;
  return { ...ctx.result, __typename: '${typeName}', id: ctx.args.id };
}
`->Pulumi.Input.make

// ---------------------------------------------------------------------------
// DynamoDB read — by primary key
// ---------------------------------------------------------------------------

// `~ownerField` / `~elevatedGroups` carry the same meaning as on
// `listAllItemsConnection`, and are optional for the same reason: a state that
// declares no owner emits exactly the source it emitted before scoping existed.
// A list that scopes beside a by-id read that does not is not a partial
// delivery — it is a hole, reachable by anyone who can name a row.
let getItemById = (~ownerField: option<string>=?, ~elevatedGroups: array<string>=[]) =>
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'GetItem',
    key: { id: util.dynamodb.toDynamoDB(ctx.args.id) }
  };
}
${ownerScopedResultResponse(~ownerField, ~elevatedGroups)}
`->Pulumi.Input.make

let queryById =
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'Query',
    query: {
      expression: 'id = :id',
      expressionValues: { ':id': util.dynamodb.toDynamoDB(ctx.args.id) }
    }
  };
}
${resultResponseCode}
`->Pulumi.Input.make

/** Query by partition key with sort-key conditions and Relay cursor pagination.
    Reads from `args.filter` object: `prefix`, `from`, `to`, `eq`, `order` (ASC/DESC).
    Relay pagination: `first`/`after` (forward) or `last`/`before` (backward).
    Cursor is base64 of the sort key value.
    Returns a Relay `{ edges, pageInfo }` shape reusing the entity's `Connection` type. */
// A list in everything but its name, so it scopes the way `listAllItemsConnection`
// does — a FilterExpression on the request, not a guard on the response. The
// response is where the page is cut, and narrowing after that cut would report
// `hasNextPage` from a count the caller was never allowed to see.
let queryItemsWithSortConditions = (
  sortField: string,
  ~ownerField: option<string>=?,
  ~elevatedGroups: array<string>=[],
) => {
  let ownerFilter = switch ownerField {
  | None => ""
  | Some(field) =>
    let elevatedLiteral = elevatedGroups->Array.map(g => `'${g}'`)->Array.join(", ")
    `
  // ── owner scoping (generated) ──
  // Not read from ctx.args, for the reason the list resolver gives: a predicate
  // deciding what the caller may see must arrive on a channel they cannot name.
  const _id = ctx.identity;
  const _sub = _id == null ? null : _id.sub;
  const _groups = (_id != null && _id.claims != null && _id.claims['cognito:groups']) || [];
  const _elevated = [${elevatedLiteral}];
  const _exempt = _sub == null || _groups.some(g => _elevated.indexOf(g) >= 0);
  const _ownerFilter = _exempt ? undefined : {
    expression: '#owner = :owner',
    expressionNames: { '#owner': '${field}' },
    expressionValues: { ':owner': util.dynamodb.toDynamoDB(_sub) },
  };`
  }
  let ownerFilterField = switch ownerField {
  | None => ""
  | Some(_) => `
    filter: _ownerFilter,`
  }
  `${importUtil}
const encodeCursor = (skValue) => util.base64Encode(skValue);
const decodeCursor = (cursor) => util.base64Decode(cursor);
export function request(ctx) {
  const args = ctx.args;
  const filter = args.filter ?? {};
  const isBackward = args.last != null;
  const expressionNames = { '#id': 'id' };
  const expressionValues = { ':id': util.dynamodb.toDynamoDB(args.id) };
  let skCondition;
  if (filter.eq != null) {
    expressionValues[':eq'] = util.dynamodb.toDynamoDB(filter.eq);
    skCondition = '#sk = :eq';
  } else if (filter.prefix != null) {
    expressionValues[':prefix'] = util.dynamodb.toDynamoDB(filter.prefix);
    skCondition = 'begins_with(#sk, :prefix)';
  } else if (filter.from != null && filter.to != null) {
    expressionValues[':from'] = util.dynamodb.toDynamoDB(filter.from);
    expressionValues[':to'] = util.dynamodb.toDynamoDB(filter.to);
    skCondition = '#sk BETWEEN :from AND :to';
  } else if (filter.from != null) {
    expressionValues[':from'] = util.dynamodb.toDynamoDB(filter.from);
    skCondition = '#sk >= :from';
  } else if (filter.to != null) {
    expressionValues[':to'] = util.dynamodb.toDynamoDB(filter.to);
    skCondition = '#sk <= :to';
  }
  if (isBackward && args.before != null) {
    const beforeKey = decodeCursor(args.before);
    expressionValues[':cursor'] = util.dynamodb.toDynamoDB(beforeKey);
    const cursorCond = '#sk < :cursor';
    skCondition = skCondition ? \`(\${skCondition}) AND \${cursorCond}\` : cursorCond;
  } else if (!isBackward && args.after != null) {
    const afterKey = decodeCursor(args.after);
    expressionValues[':cursor'] = util.dynamodb.toDynamoDB(afterKey);
    const cursorCond = '#sk > :cursor';
    skCondition = skCondition ? \`(\${skCondition}) AND \${cursorCond}\` : cursorCond;
  }
  if (skCondition) expressionNames['#sk'] = '${sortField}';
  const expression = skCondition ? \`#id = :id AND \${skCondition}\` : '#id = :id';
  const orderDesc = filter.order === 'DESC';
  const scanForward = isBackward ? orderDesc : !orderDesc;
  const pageSize = isBackward ? (args.last ?? 50) : (args.first ?? 50);${ownerFilter}
  return {
    operation: 'Query',
    query: { expression, expressionNames, expressionValues },${ownerFilterField}
    scanIndexForward: scanForward,
    limit: pageSize + 1,
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  const args = ctx.args;
  const filter = args.filter ?? {};
  const isBackward = args.last != null;
  const pageSize = isBackward ? (args.last ?? 50) : (args.first ?? 50);
  let items = ctx.result.items ?? [];
  const hasMore = items.length > pageSize;
  if (hasMore) items = items.slice(0, pageSize);
  if (isBackward) items = items.reverse();
  const edges = items.map(item => ({ node: item, cursor: encodeCursor(item['${sortField}'] ?? '') }));
  const startCursor = edges.length > 0 ? edges[0].cursor : null;
  const endCursor = edges.length > 0 ? edges[edges.length - 1].cursor : null;
  return {
    edges,
    pageInfo: {
      hasNextPage: !isBackward && hasMore,
      hasPreviousPage: isBackward && hasMore,
      startCursor,
      endCursor,
    },
  };
}
`->Pulumi.Input.make
}

let queryByIdSort = (
  sortField: string,
  ~ownerField: option<string>=?,
  ~elevatedGroups: array<string>=[],
) =>
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'Query',
    query: {
      expression: 'id = :id AND #${sortField} = :${sortField}',
      expressionNames: { '#${sortField}': '${sortField}' },
      expressionValues: {
        ':id': util.dynamodb.toDynamoDB(ctx.args.id),
        ':${sortField}': util.dynamodb.toDynamoDB(ctx.args.${sortField})
      }
    }
  };
}
${ownerScopedFirstResultResponse(~ownerField, ~elevatedGroups)}
`->Pulumi.Input.make

// ---------------------------------------------------------------------------
// DynamoDB read — by index
// ---------------------------------------------------------------------------

let queryByIndex = (index: string) =>
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'Query',
    query: {
      expression: '#${index} = :${index}',
      expressionNames: { '#${index}': '${index}' },
      expressionValues: { ':${index}': util.dynamodb.toDynamoDB(ctx.args.${index}) }
    },
    index: '${index}'
  };
}
${resultResponseCode}
`->Pulumi.Input.make

let queryByIndexDeletable = (index: string) =>
  `${importUtil}
export function request(ctx) {
  const req = {
    operation: 'Query',
    query: {
      expression: '#${index} = :${index}',
      expressionNames: { '#${index}': '${index}' },
      expressionValues: { ':${index}': util.dynamodb.toDynamoDB(ctx.args.${index}) }
    },
    index: '${index}'
  };
  if (ctx.args.hideDeleted) {
    req.filter = {
      expression: '#deleted = :false',
      expressionNames: { '#deleted': 'deleted' },
      expressionValues: { ':false': util.dynamodb.toBoolean(false) }
    };
  }
  return req;
}
${resultResponseCode}
`->Pulumi.Input.make

let queryByIndexSort = (~index: string, ~idField: string, ~sortField: string) =>
  `${importUtil}
export function request(ctx) {
  const query = ctx.args.${sortField}
    ? {
        expression: '#${idField} = :${idField} AND #${sortField} = :${sortField}',
        expressionNames: { '#${idField}': '${idField}', '#${sortField}': '${sortField}' },
        expressionValues: {
          ':${idField}': util.dynamodb.toDynamoDB(ctx.args.${idField}),
          ':${sortField}': util.dynamodb.toDynamoDB(ctx.args.${sortField})
        }
      }
    : {
        expression: '#${idField} = :${idField}',
        expressionNames: { '#${idField}': '${idField}' },
        expressionValues: { ':${idField}': util.dynamodb.toDynamoDB(ctx.args.${idField}) }
      };
  return { operation: 'Query', query, index: '${index}' };
}
${resultResponseCode}
`->Pulumi.Input.make

// AppSync JS runtime restrictions (APPSYNC_JS 1.0.0):
//   - No `for` loops (for/for-of/for-in all fail validation)
//   - No String() / .toString() — use '' + value instead
//   - Object.keys().forEach() works for iteration
let queryByIndexFiltered = (~index: string, ~idField: string) =>
  `${importUtil}
export function request(ctx) {
  const args = ctx.args;
  const query = {
    expression: '#${idField} = :${idField}',
    expressionNames: { '#${idField}': '${idField}' },
    expressionValues: { ':${idField}': util.dynamodb.toDynamoDB(args.${idField}) }
  };
  let expression = '';
  const names = {};
  const values = {};
  Object.keys(args).forEach(key => {
    const value = args[key];
    if (key === '${idField}' || key === 'limit' || key === 'nextToken' || key === 'forward') return;
    if (value == null || value === '') return;
    if (expression) expression += ' AND';
    if (key === 'hideDeleted') {
      if (value === true) {
        expression += ' #deleted = :false';
        names['#deleted'] = 'deleted';
        values[':false'] = false;
      }
    } else {
      expression += ' contains(#' + key + ', :' + key + ')';
      names['#' + key] = key;
      values[':' + key] = '' + value;
    }
  });
  const result = {
    operation: 'Query',
    query,
    index: '${index}',
    limit: (args.limit ?? 50),
    nextToken: (args.nextToken ?? null),
    scanIndexForward: (args.forward ?? true)
  };
  if (expression) {
    result.filter = { expression, expressionNames: names, expressionValues: util.dynamodb.toMapValues(values) };
  }
  return result;
}
${resultResponseCode}
`->Pulumi.Input.make

let queryByIndexSortFiltered = (~index: string, ~idField: string, ~sortField: string) =>
  `${importUtil}
export function request(ctx) {
  const args = ctx.args;
  const query = args.${sortField}
    ? {
        expression: '#${idField} = :${idField} AND #${sortField} = :${sortField}',
        expressionNames: { '#${idField}': '${idField}', '#${sortField}': '${sortField}' },
        expressionValues: {
          ':${idField}': util.dynamodb.toDynamoDB(args.${idField}),
          ':${sortField}': util.dynamodb.toDynamoDB(args.${sortField})
        }
      }
    : {
        expression: '#${idField} = :${idField}',
        expressionNames: { '#${idField}': '${idField}' },
        expressionValues: { ':${idField}': util.dynamodb.toDynamoDB(args.${idField}) }
      };
  let expression = '';
  const names = {};
  const values = {};
  Object.keys(args).forEach(key => {
    const value = args[key];
    if (key === '${idField}' || key === '${sortField}' || key === 'limit' || key === 'nextToken' || key === 'forward') return;
    if (value == null || value === '') return;
    if (expression) expression += ' AND';
    if (key === 'hideDeleted') {
      if (value === true) {
        expression += ' #deleted = :false';
        names['#deleted'] = 'deleted';
        values[':false'] = false;
      }
    } else {
      expression += ' contains(#' + key + ', :' + key + ')';
      names['#' + key] = key;
      values[':' + key] = '' + value;
    }
  });
  const result = {
    operation: 'Query',
    query,
    index: '${index}',
    limit: (args.limit ?? 50),
    nextToken: (args.nextToken ?? null),
    scanIndexForward: (args.forward ?? true)
  };
  if (expression) {
    result.filter = { expression, expressionNames: names, expressionValues: util.dynamodb.toMapValues(values) };
  }
  return result;
}
${resultResponseCode}
`->Pulumi.Input.make

// ---------------------------------------------------------------------------
// DynamoDB read — list all
// ---------------------------------------------------------------------------

let listAllItems =
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'Scan',
    limit: (ctx.args.limit ?? 50),
    nextToken: (ctx.args.nextToken ?? null)
  };
}
${resultResponseCode}
`->Pulumi.Input.make

// ---------------------------------------------------------------------------
// DynamoDB read — list all (Relay Connection spec)
// ---------------------------------------------------------------------------

/**
 * Scan with optional `filter` arg: `{search?, searchPrefix?, ids?, <field>Eq?, <field>From?, <field>To?}`
 * and optional `orderBy: {field, direction}`.
 *
 * `search`       → `contains(labelField, :v)` — case-sensitive on DynamoDB. Callers that
 *                  need case-insensitive matching should project a lowercased label column
 *                  (future Phase 6.1 / external full-text search).
 * `searchPrefix` → `begins_with(labelField, :v)` — case-sensitive. Scan-only here;
 *                  Phase 6 `@searchable` provisions a GSI to promote this to a query.
 * `ids`          → FilterExpression `#id IN (:id0, :id1, …)`. Simple scan-based
 *                  path; BatchGetItem optimisation is deferred (open question 1).
 * `<field>Eq`    → FilterExpression `#<field> = :<field>Eq`, one per `~filterFields` entry.
 * `<field>From`  → FilterExpression `#<field> >= :<field>From`, one per `~rangeFields` entry.
 * `<field>To`    → FilterExpression `#<field> <= :<field>To`, one per `~rangeFields` entry.
 * `orderBy`      → JS-runtime sort over the returned page when `orderBy.field` is in
 *                  `~sortFields`. **Per-page only**, not global — DynamoDB Scan returns
 *                  items in indeterminate order and `ScanIndexForward` does not apply
 *                  to Scan. Index-routed Query (v1.5) lifts this caveat for indexed
 *                  sort fields; `@scanSort` on a non-indexed field is per-page even then.
 *
 * Empty-string and null filter values are treated as "no filter" — consistent with the
 * in-memory adapter so clients don't need to conditionally omit keys.
 */
let listAllItemsConnection = (
  ~labelField: string,
  ~filterFields: array<string>=[],
  ~rangeFields: array<string>=[],
  ~sortFields: array<string>=[],
  // When set, emit an always-on `attribute_exists(#<attr>)` FilterExpression clause
  // (ANDed with any client filters) so rows lacking that attribute never enter the
  // Connection. Used for read models whose physical DynamoDB table co-hosts internal
  // bookkeeping rows written outside the projection (e.g. the Plugins admin RM, whose
  // table also holds `deploy-schema:*` / `plugin-info:*` rows with no `name`). Those
  // rows would otherwise resolve `name`/`status`/`version` to null and violate the
  // non-null GraphQL connection schema, nulling the whole connection.
  ~requireAttribute: option<string>=?,
  // The state's `@owner` field, when it declares one, plus the groups exempt from
  // scoping. Baked into the generated source because this resolver runs inside
  // AppSync with no Lambda in the path — there is nothing here that could read a
  // configuration value at request time, so the deploy is the only chance to
  // state it. Changing the elevated-group list therefore requires a redeploy,
  // which is worth knowing and is why it is a deployment-level setting rather
  // than a per-request one.
  ~ownerField: option<string>=?,
  ~elevatedGroups: array<string>=[],
  // The state's `@retired` field, when it declares one. Baked in for the same
  // reason `ownerField` is: there is no Lambda in this path to read it at
  // request time.
  ~retiredField: option<string>=?,
  // The states that retire the row, for the state form of the annotation.
  // Absent is the boolean form, where the value is always `true`.
  ~retiredValues: option<array<string>>=?,
) => {
  let requireAttributeClause = switch requireAttribute {
  | Some(attr) => `
  names['#${attr}'] = '${attr}';
  parts.push('attribute_exists(#${attr})');`
  | None => ""
  }
  // Mirrors `Reventless.OwnerScope.resolve`, in the one place that cannot call
  // it. The branch ORDER is the part that has to match: provider first, because
  // an IAM-signed service caller has no `sub` for a reason that has nothing to do
  // with being anonymous, and must not be refused as though it did.
  let ownerClause = switch ownerField {
  | None => ""
  | Some(field) =>
    let elevatedLiteral = elevatedGroups->Array.map(g => `'${g}'`)->Array.join(", ")
    `
  // ── owner scoping (generated) ──
  // Not read from ctx.args: a predicate deciding what the caller may see must
  // arrive on a channel the caller cannot name, and this field is usually absent
  // from the filter surface anyway.
  const _id = ctx.identity;
  const _sub = _id == null ? null : _id.sub;
  const _groups = (_id != null && _id.claims != null && _id.claims['cognito:groups']) || [];
  const _elevated = [${elevatedLiteral}];
  // No identity at all, or an identity with no \`sub\`, is the IAM service caller
  // the API also accepts — inside the trust boundary, and exempt.
  const _exempt = _sub == null || _groups.some(g => _elevated.indexOf(g) >= 0);
  if (!_exempt) {
    names['#owner'] = '${field}';
    values[':owner'] = util.dynamodb.toDynamoDB(_sub);
    parts.push('#owner = :owner');
  }`
  }
  // ── retirement narrowing (generated) ──
  // Reuses `_exempt` when the owner clause already computed it, and computes its
  // own when it did not — the two clauses are independently optional and either
  // may be the only one present.
  //
  // `includeRetired` IS read from ctx.args, unlike the owner predicate, and the
  // difference is deliberate: this argument does not say which rows the caller
  // wants, it asks to lift a restriction, and it is honoured only inside the
  // `_exempt` branch. A non-exempt caller passing it changes nothing.
  //
  // `attribute_not_exists OR = false` rather than `<> true`: a row written before
  // the annotation existed carries no such attribute, and DynamoDB's `<>` does
  // not match a missing one — the whole view would come back empty on the day
  // the annotation lands.
  //
  // The state form compares `<>` against the retiring state instead, under the
  // same `attribute_not_exists` guard and for the same reason. An equality
  // predicate over an enum-valued attribute indexes exactly as a boolean one
  // does, so the warning about an unindexed retirement field carries over
  // unchanged.
  let retiredClause = switch retiredField {
  | None => ""
  | Some(field) =>
    let elevatedLiteral = elevatedGroups->Array.map(g => `'${g}'`)->Array.join(", ")
    let exemptPrelude = switch ownerField {
    | Some(_) => ""
    | None => `
  const _id = ctx.identity;
  const _sub = _id == null ? null : _id.sub;
  const _groups = (_id != null && _id.claims != null && _id.claims['cognito:groups']) || [];
  const _elevated = [${elevatedLiteral}];
  const _exempt = _sub == null || _groups.some(g => _elevated.indexOf(g) >= 0);`
    }
    `${exemptPrelude}
  // ── retirement narrowing (generated) ──
  const _wantsRetired = _exempt && ctx.args.includeRetired === true;
  if (!_wantsRetired) {
    names['#retired'] = '${field}';
${switch retiredValues {
      | None => `    values[':retiredFalse'] = util.dynamodb.toDynamoDB(false);
    parts.push('(attribute_not_exists(#retired) OR #retired = :retiredFalse)');`
      // One `<>` per state, ANDed, rather than `NOT IN`: DynamoDB's `IN` needs a
      // parenthesised operand list built from the same placeholders anyway, and
      // the conjunction keeps `attribute_not_exists` covering the absent case
      // once for the whole clause — a row that states no lifecycle is not
      // retired, the same reading every other adapter takes.
      | Some(states) =>
        let placeholders = states->Array.mapWithIndex((state, i) => (`:retiredValue${Int.toString(i)}`, state))
        let assignments =
          placeholders
          ->Array.map(((ph, state)) => `    values['${ph}'] = util.dynamodb.toDynamoDB('${state}');`)
          ->Array.join("\n")
        let comparisons =
          placeholders->Array.map(((ph, _)) => `#retired <> ${ph}`)->Array.join(" AND ")
        // A set naming nothing withdraws nothing, so it pushes no predicate down.
        switch placeholders {
        | [] => ""
        | _ =>
          `${assignments}
    parts.push('(attribute_not_exists(#retired) OR (${comparisons}))');`
        }
      }}
  }`
  }
  let filterClauses =
    filterFields
    ->Array.map(f => `
  if (filter.${f}Eq !== undefined && filter.${f}Eq !== null && filter.${f}Eq !== '') {
    names['#${f}'] = '${f}';
    values[':${f}Eq'] = util.dynamodb.toDynamoDB(filter.${f}Eq);
    parts.push('#${f} = :${f}Eq');
  }`)
    ->Array.join("")
  let rangeClauses =
    rangeFields
    ->Array.map(f => `
  if (filter.${f}From !== undefined && filter.${f}From !== null && filter.${f}From !== '') {
    names['#${f}'] = '${f}';
    values[':${f}From'] = util.dynamodb.toDynamoDB(filter.${f}From);
    parts.push('#${f} >= :${f}From');
  }
  if (filter.${f}To !== undefined && filter.${f}To !== null && filter.${f}To !== '') {
    names['#${f}'] = '${f}';
    values[':${f}To'] = util.dynamodb.toDynamoDB(filter.${f}To);
    parts.push('#${f} <= :${f}To');
  }`)
    ->Array.join("")
  let sortFieldsLiteral =
    sortFields->Array.map(f => `'${f}'`)->Array.join(", ")
  let sortBlock = if sortFields->Array.length == 0 {
    ""
  } else {
    // APPSYNC_JS 1.0.0 forbids: Array.prototype.sort(comparator), arrow/function
    // expressions passed to sort, for/while loops, recursion, and ++/--. So we
    // can't run a comparator-driven sort and we can't write our own loop. Use a
    // schwartzian transform: encode each item as `<sortKey>\x01<json>`, run the
    // no-comparator default sort (lexicographic), reverse for DESC, and decode.
    // Numeric fields get zero-padded so lex order matches numeric order for
    // non-negative values (typical for IDs, counts, timestamps). Negatives sort
    // lexicographically — acceptable since DynamoDB sort keys are rarely signed
    // numbers. Nulls split out and append to the end regardless of direction.
    `
  // Per-page sort (Scan returns items in indeterminate order; ScanIndexForward
  // does not apply to Scan). Global ordering across pages requires v1.5 index
  // promotion; @scanSort is per-page even then.
  const orderBy = ctx.args.orderBy;
  const sortFields = [${sortFieldsLiteral}];
  if (orderBy && orderBy.field && sortFields.indexOf(orderBy.field) >= 0) {
    const field = orderBy.field;
    const nulls = items.filter(it => it[field] === null || it[field] === undefined);
    const nonNulls = items.filter(it => it[field] !== null && it[field] !== undefined);
    const encoded = nonNulls.map(it => {
      const v = it[field];
      const key = (typeof v === 'number')
        ? ('0000000000000000000000' + v).slice(-22)
        : ('' + v);
      return key + '\\x01' + JSON.stringify(it);
    });
    encoded.sort();
    if (orderBy.direction === 'DESC') encoded.reverse();
    items = encoded.map(e => JSON.parse(e.split('\\x01')[1])).concat(nulls);
  }`
  }
  `${importUtil}
export function request(ctx) {
  // Scan cannot page backward (ScanIndexForward is Query-only). Fail loud rather than
  // silently returning the forward page. The ordered {single}Items connection
  // (queryItemsWithSortConditions) supports last/before — direct backward callers there.
  if (ctx.args.before != null || ctx.args.last != null) {
    util.error('Backward pagination (last/before) is not supported on full-list connections; use first/after.', 'UnsupportedPagination');
  }
  const filter = ctx.args.filter ?? {};
  const names = {};
  const values = {};
  const parts = [];
  if (typeof filter.search === 'string' && filter.search.length > 0) {
    names['#label'] = '${labelField}';
    values[':search'] = util.dynamodb.toDynamoDB(filter.search);
    parts.push('contains(#label, :search)');
  }
  if (typeof filter.searchPrefix === 'string' && filter.searchPrefix.length > 0) {
    names['#label'] = '${labelField}';
    values[':searchPrefix'] = util.dynamodb.toDynamoDB(filter.searchPrefix);
    parts.push('begins_with(#label, :searchPrefix)');
  }
  if (Array.isArray(filter.ids) && filter.ids.length > 0) {
    names['#id'] = 'id';
    const placeholders = filter.ids.map((id, i) => {
      const key = ':id' + i;
      values[key] = util.dynamodb.toDynamoDB(id);
      return key;
    });
    parts.push('#id IN (' + placeholders.join(', ') + ')');
  }${filterClauses}${rangeClauses}${requireAttributeClause}${ownerClause}${retiredClause}
  // The cursor is base64(JSON({ token, index })); decode the after arg back to the raw
  // DynamoDB continuation token the response side emitted (Fix 1 round-trip).
  let after = null;
  if (ctx.args.after != null && ctx.args.after !== '') {
    const parsed = JSON.parse(util.base64Decode(ctx.args.after));
    after = parsed.token ?? null;
  }
  const req = {
    operation: 'Scan',
    limit: (ctx.args.first ?? 50),
    nextToken: after,
  };
  if (parts.length > 0) {
    req.filter = {
      expression: parts.join(' AND '),
      expressionNames: names,
      expressionValues: values,
    };
  }
  return req;
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  let items = ctx.result?.items ?? [];${sortBlock}
  // One Scan continuation token per page; encode it (with the item's page index for a
  // unique, opaque Relay cursor). The request side decodes .token back to the raw
  // DynamoDB nextToken (Fix 1).
  const next = ctx.result?.nextToken ?? null;
  const edges = items.map((item, i) => ({
    node: item,
    cursor: util.base64Encode(JSON.stringify({ token: next, index: i })),
  }));
  // A filtered/1MB-capped page can be empty or short while next is still set (limit
  // caps rows scanned, not returned). The token is page-level, so synthesise a
  // boundary cursor from it alone so a client can resume past a fully-filtered-out
  // page instead of restarting from page 1 (Fix 3). The request only reads .token,
  // so index -1 is inert on resume.
  const boundary = next ? util.base64Encode(JSON.stringify({ token: next, index: -1 })) : null;
  return {
    edges,
    pageInfo: {
      hasNextPage: !!next,
      hasPreviousPage: !!ctx.args.after,
      startCursor: edges.length > 0 ? edges[0].cursor : boundary,
      endCursor: edges.length > 0 ? edges[edges.length - 1].cursor : boundary,
    },
  };
}
`->Pulumi.Input.make
}

// ---------------------------------------------------------------------------
// DynamoDB nested resolvers — resolve linked item(s) by ID
// ---------------------------------------------------------------------------

let resolveId = (~sourceIdField: string) =>
  `${importUtil}
export function request(ctx) {
  if (!ctx.source.${sourceIdField}) return runtime.earlyReturn(null);
  return {
    operation: 'Query',
    query: {
      expression: '#id = :id',
      expressionNames: { '#id': 'id' },
      expressionValues: { ':id': util.dynamodb.toDynamoDB(ctx.source.${sourceIdField}) }
    },
    limit: (ctx.args.limit ?? 50),
    nextToken: (ctx.args.nextToken ?? null),
    scanIndexForward: (ctx.args.forward ?? true)
  };
}
${firstResultResponseCode}
`->Pulumi.Input.make

let resolveIdSort = (~sourceIdField: string, ~sourceSortField: string, ~targetSortField: string) =>
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'Query',
    query: {
      expression: '#id = :id AND #${targetSortField} = :${targetSortField}',
      expressionNames: { '#id': 'id', '#${targetSortField}': '${targetSortField}' },
      expressionValues: {
        ':id': util.dynamodb.toDynamoDB(ctx.source.${sourceIdField}),
        ':${targetSortField}': util.dynamodb.toDynamoDB(ctx.source.${sourceSortField})
      }
    },
    limit: (ctx.args.limit ?? 50),
    nextToken: (ctx.args.nextToken ?? null),
    scanIndexForward: (ctx.args.forward ?? true)
  };
}
${firstResultResponseCode}
`->Pulumi.Input.make

let resolveIdSortArgument = (
  ~sourceIdField: string,
  ~sourceSortArgument: string,
  ~targetSortField: string,
) =>
  `${importUtil}
export function request(ctx) {
  const query = ctx.args.${sourceSortArgument}
    ? {
        expression: '#id = :id AND #${targetSortField} = :${targetSortField}',
        expressionNames: { '#id': 'id', '#${targetSortField}': '${targetSortField}' },
        expressionValues: {
          ':id': util.dynamodb.toDynamoDB(ctx.source.${sourceIdField}),
          ':${targetSortField}': util.dynamodb.toDynamoDB(ctx.args.${sourceSortArgument})
        }
      }
    : {
        expression: '#id = :id',
        expressionNames: { '#id': 'id' },
        expressionValues: { ':id': util.dynamodb.toDynamoDB(ctx.source.${sourceIdField}) }
      };
  return {
    operation: 'Query',
    query,
    limit: (ctx.args.limit ?? 50),
    nextToken: (ctx.args.nextToken ?? null),
    scanIndexForward: (ctx.args.forward ?? true)
  };
}
${firstResultResponseCode}
`->Pulumi.Input.make

// ---------------------------------------------------------------------------
// DynamoDB nested resolvers — resolve by index
// ---------------------------------------------------------------------------

let resolveIdByIndex = (~index: string, ~sourceIdField: string, ~targetIdField: string) =>
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'Query',
    query: {
      expression: '#${targetIdField} = :${targetIdField}',
      expressionNames: { '#${targetIdField}': '${targetIdField}' },
      expressionValues: { ':${targetIdField}': util.dynamodb.toDynamoDB(ctx.source.${sourceIdField}) }
    },
    index: '${index}',
    limit: (ctx.args.limit ?? 50),
    nextToken: (ctx.args.nextToken ?? null),
    scanIndexForward: (ctx.args.forward ?? true)
  };
}
${firstResultResponseCode}
`->Pulumi.Input.make

let resolveIdByIndexSort = (
  ~index: string,
  ~sourceIdField: string,
  ~sourceSortField: string,
  ~targetIdField: string,
  ~targetSortField: string,
) =>
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'Query',
    query: {
      expression: '#${targetIdField} = :${targetIdField} AND #${targetSortField} = :${targetSortField}',
      expressionNames: { '#${targetIdField}': '${targetIdField}', '#${targetSortField}': '${targetSortField}' },
      expressionValues: {
        ':${targetIdField}': util.dynamodb.toDynamoDB(ctx.source.${sourceIdField}),
        ':${targetSortField}': util.dynamodb.toDynamoDB(ctx.source.${sourceSortField})
      }
    },
    index: '${index}',
    limit: (ctx.args.limit ?? 50),
    nextToken: (ctx.args.nextToken ?? null),
    scanIndexForward: (ctx.args.forward ?? true)
  };
}
${firstResultResponseCode}
`->Pulumi.Input.make

let resolveIdByIndexSortArgument = (
  ~index: string,
  ~sourceIdField: string,
  ~sourceSortArgument: string,
  ~targetIdField: string,
  ~targetSortField: string,
) =>
  `${importUtil}
export function request(ctx) {
  const query = ctx.args.${sourceSortArgument}
    ? {
        expression: '#${targetIdField} = :${targetIdField} AND #${targetSortField} = :${targetSortField}',
        expressionNames: { '#${targetIdField}': '${targetIdField}', '#${targetSortField}': '${targetSortField}' },
        expressionValues: {
          ':${targetIdField}': util.dynamodb.toDynamoDB(ctx.source.${sourceIdField}),
          ':${targetSortField}': util.dynamodb.toDynamoDB(ctx.args.${sourceSortArgument})
        }
      }
    : {
        expression: '#${targetIdField} = :${targetIdField}',
        expressionNames: { '#${targetIdField}': '${targetIdField}' },
        expressionValues: { ':${targetIdField}': util.dynamodb.toDynamoDB(ctx.source.${sourceIdField}) }
      };
  return {
    operation: 'Query',
    query,
    index: '${index}',
    limit: (ctx.args.limit ?? 50),
    nextToken: (ctx.args.nextToken ?? null),
    scanIndexForward: (ctx.args.forward ?? true)
  };
}
${firstResultResponseCode}
`->Pulumi.Input.make

// resolveIds — returns a plain string (table name is interpolated by the adapter
// via Pulumi.Output.apply)
let resolveIds = (tableName: string, ~idsField: string, ~sortField: option<string>) => {
  let keysCode = switch sortField {
  | Some(sf) =>
    `id => ({ id: util.dynamodb.toString(id.id), ${sf}: util.dynamodb.toString(id.${sf}) })`
  | None => `id => ({ id: util.dynamodb.toString(id) })`
  }
  `${importUtil}
import { runtime } from '@aws-appsync/utils';
export function request(ctx) {
  const idList = ctx.source.${idsField};
  if (idList && idList.length > 0) {
    return {
      operation: 'BatchGetItem',
      tables: {
        '${tableName}': {
          keys: idList.map(${keysCode}),
          consistentRead: true
        }
      }
    };
  }
  return { operation: 'GetItem', key: { id: util.dynamodb.toString(ctx.source.id) } };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`
}

/** Batched-by-ids — top-level Query resolver reading `ctx.args.ids: [String!]!`
    and returning the matching items via a single BatchGetItem. Missing ids drop
    out (BatchGetItem does not preserve cardinality); empty input short-circuits
    to an empty result without hitting DDB. Table name is interpolated at deploy
    time, since BatchGetItem's `tables` map keys on the literal table name.
    Single-key tables only — composite-key BatchGetItem needs both pk + sk per
    key entry, which this template doesn't construct. */
let batchGetItemsByIds = (tableName: string) =>
  `${importUtil}
import { runtime } from '@aws-appsync/utils';
export function request(ctx) {
  const ids = ctx.args.ids ?? [];
  if (ids.length === 0) return runtime.earlyReturn([]);
  return {
    operation: 'BatchGetItem',
    tables: {
      '${tableName}': {
        keys: ids.map(id => ({ id: util.dynamodb.toDynamoDB(id) })),
        consistentRead: true,
      }
    }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  // BatchGetItem returns null in the result array for keys that don't exist
  // in the table, preserving index correspondence with the input. The SDL
  // returns this field as \`[T!]!\` (non-null element list), so any single
  // missing id makes the entire field fail with "Cannot return null for
  // non-nullable type" and the caller sees data=null. Filter the nulls so
  // the field returns just the items that were found.
  return (ctx.result?.data?.['${tableName}'] ?? []).filter(item => item !== null);
}
`

// ---------------------------------------------------------------------------
// DynamoDB write
// ---------------------------------------------------------------------------

let putItem =
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'PutItem',
    key: { id: util.dynamodb.toDynamoDB(ctx.args.id) },
    attributeValues: util.dynamodb.toMapValues(ctx.args)
  };
}
${resultResponseCode}
`->Pulumi.Input.make

let addItemToList = (~listName: string, ~itemName: string) =>
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'UpdateItem',
    key: { id: util.dynamodb.toDynamoDB(ctx.args.id) },
    update: {
      expression: 'SET #list = list_append(#list, :item)',
      expressionNames: { '#list': '${listName}' },
      expressionValues: { ':item': util.dynamodb.toList([util.dynamodb.toDynamoDB(ctx.args.${itemName})]) }
    }
  };
}
${resultResponseCode}
`->Pulumi.Input.make

let deleteItem =
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'DeleteItem',
    key: { id: util.dynamodb.toString(ctx.args.id) }
  };
}
${resultResponseCode}
`->Pulumi.Input.make

// ---------------------------------------------------------------------------
// Lambda invocations
// ---------------------------------------------------------------------------

/** Invoke a CommandGenerator Lambda. `command` is the Aggregate command name. */
let invokeCommandGenerator = (command: string) =>
  `${importUtil}
export function request(ctx) {
  const id = ctx.identity;
  const isCognito = id != null && id.sub != null;
  return {
    operation: 'Invoke',
    payload: {
      command: '${command}',
      arguments: ctx.args,
      meta: {
        ip: id?.sourceIp ?? null,
        user: id?.username ?? null,
        info: ctx.info.parentTypeName + '.' + ctx.info.fieldName
      },
      identity: isCognito
        ? {
            userId: id.sub,
            username: id.username,
            groups: id.claims?.['cognito:groups'] ?? [],
            claims: id.claims,
            provider: 'Cognito'
          }
        : id != null
          ? {
              userArn: id.userArn ?? null,
              accountId: id.accountId ?? null,
              username: id.username ?? null,
              provider: 'IAM'
            }
          : null
    }
  };
}
${resultResponseCode}
`->Pulumi.Input.make

/** Invoke a DCB Lambda. `tag` is the DCB entity tag. */
let invokeDcbMutation = (tag: string) =>
  `${importUtil}
export function request(ctx) {
  const id = ctx.identity;
  const isCognito = id != null && id.sub != null;
  return {
    operation: 'Invoke',
    payload: {
      command: '${tag}',
      arguments: ctx.args,
      meta: {
        ip: id?.sourceIp ?? null,
        user: id?.username ?? null,
        info: ctx.info.parentTypeName + '.' + ctx.info.fieldName
      },
      identity: isCognito
        ? {
            userId: id.sub,
            username: id.username,
            groups: id.claims?.['cognito:groups'] ?? [],
            claims: id.claims,
            provider: 'Cognito'
          }
        : id != null
          ? {
              userArn: id.userArn ?? null,
              accountId: id.accountId ?? null,
              username: id.username ?? null,
              provider: 'IAM'
            }
          : null
    }
  };
}
${resultResponseCode}
`->Pulumi.Input.make

/** Invoke an InboundTranslation Lambda. `fieldName` is the mutation field. */
let invokeInboundTranslation = (fieldName: string) =>
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'Invoke',
    payload: {
      __inboundTranslation: true,
      fieldName: '${fieldName}',
      arguments: ctx.args
    }
  };
}
${resultResponseCode}
`->Pulumi.Input.make

// ---------------------------------------------------------------------------
// Authorization (pipeline function fragments)
// ---------------------------------------------------------------------------

let uncapitalize = str =>
  switch String.get(str, 0) {
  | None => ""
  | Some(first) => String.concat(first->String.toLowerCase, String.slice(str, ~start=1))
  }

/** Combined pipeline function: checks group membership, fetches the item, and
    verifies the item's owner matches the requesting user.
    Replaces the two separate VTL authorizeIndexedAccessRequest/Response templates,
    which were the request and response halves of the same AppSync Function. */
let authorizeIndexedAccess = (~index: string, ~group: string) => {
  let authIdName = group->uncapitalize ++ "Id"
  `${importUtil}
import { runtime } from '@aws-appsync/utils';
export function request(ctx) {
  const groups = ctx.identity.claims?.['cognito:groups'] ?? [];
  if (groups.includes('${group}')) {
    return { operation: 'GetItem', key: { id: util.dynamodb.toDynamoDB(ctx.args.${index}) } };
  }
  return runtime.earlyReturn({ ${authIdName}: [ctx.identity.username] });
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  if (ctx.result.${authIdName} === ctx.identity.username) return ctx.result;
  return util.unauthorized();
}
`->Pulumi.Input.make
}

/** @deprecated Use authorizeIndexedAccess — kept for naming continuity with VTL templates. */
let authorizeIndexedAccessRequest = authorizeIndexedAccess

/** @deprecated The response check is now part of authorizeIndexedAccess. */
let authorizeIndexedAccessResponse = (~group as _: string) =>
  resultResponseCode->Pulumi.Input.make

// ---------------------------------------------------------------------------
// Response-only helpers
// (kept for adapter compatibility; these are now embedded in each resolver above)
// ---------------------------------------------------------------------------

let result = resultResponseCode->Pulumi.Input.make
let firstResult = firstResultResponseCode->Pulumi.Input.make
let resultList = resultListResponseCode->Pulumi.Input.make

let resolveIdResult = (tableName: string, ~idField: string) =>
  `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  if (ctx.source.${idField}) return ctx.result.data['${tableName}'][0] ?? null;
  return null;
}
`->Pulumi.Input.make

let resolveIdResults = (tableName: string, ~idField: string) =>
  `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  if (ctx.source.${idField}) return ctx.result.data['${tableName}'] ?? null;
  return null;
}
`

let resolveIdsResult = (tableName: string, ~idsField: string) =>
  `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  const idList = ctx.source.${idsField};
  return (idList && idList.length > 0) ? ctx.result.data['${tableName}'] : [];
}
`

let null = `
export function response(ctx) { return null; }
`->Pulumi.Input.make
