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
The caller-is-exempt test, emitted into a resolver's response. Mirrors
`Reventless.OwnerScope.resolve`, branch order included — an IAM-signed caller has
no `sub` because it is inside the trust boundary, not because it is anonymous.
In the response because `GetItem` has no FilterExpression; `Query` follows it so
one rule keeps one implementation.
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
The exemption test alone, for a door that narrows retirement but declares no
`@owner`. Emitted only when `ownerGuardPreamble` is absent — two `const _exempt`
in one body is a syntax error, and two different ones would be worse.
*/
let exemptPreamble = (~elevatedGroups: array<string>) => {
  let elevatedLiteral = elevatedGroups->Array.map(g => `'${g}'`)->Array.join(", ")
  `
  const _id = ctx.identity;
  const _sub = _id == null ? null : _id.sub;
  const _groups = (_id != null && _id.claims != null && _id.claims['cognito:groups']) || [];
  const _elevated = [${elevatedLiteral}];
  const _exempt = _sub == null || _groups.some(g => _elevated.indexOf(g) >= 0);`
}

/**
A by-key read's retirement guard: `_live(row)`, true when the caller may see it.
The post-read half of what `listAllItemsConnection` pushes into a
FilterExpression — `GetItem` has none to push into.

`row[field] == null` keeps a row written before the annotation existed. Exemption
alone withholds a retired row until `includeRetired` is passed, so an operator's
ordinary read is as narrow as anyone's.

`~ownerScoped` says an `ownerGuardPreamble` already declared `_exempt` here.
*/
let retiredGuardPreamble = (
  ~retiredField: option<string>,
  ~retiredValues: option<array<string>>,
  ~elevatedGroups: array<string>,
  ~ownerScoped: bool,
) =>
  switch retiredField {
  | None => ""
  | Some(field) =>
    let prelude = ownerScoped ? "" : exemptPreamble(~elevatedGroups)
    let isRetired = switch retiredValues {
    | None => `row['${field}'] === true`
    | Some(states) =>
      let literal = states->Array.map(s => `'${s}'`)->Array.join(", ")
      `[${literal}].indexOf(row['${field}']) >= 0`
    }
    `${prelude}
  // ── retirement narrowing (generated) ──
  const _wantsRetired = _exempt && ctx.args.includeRetired === true;
  const _live = (row) =>
    row == null || _wantsRetired || row['${field}'] == null || !(${isRetired});`
  }

/**
The `@owner` predicate for an index door, as a FilterExpression clause. Same rule
and branch order as `listAllItemsConnection`'s, and pushed into the read for the
same reason.

**Not applied to a group-restricted index.** There `authorizeIndexedAccess`
already gates the caller, and the rows are by construction other people's — an
order assigned to a fulfilment operator is owned by the customer who placed it —
so ANDing `@owner` on top would revoke exactly what the auth table granted.
`QueryDbResolvers_AppSync` passes `ownerField` only for doors with no such rule.
*/
let ownerFilterClause = (~ownerField: option<string>, ~elevatedGroups: array<string>) =>
  switch ownerField {
  | None => ""
  | Some(field) =>
    let elevatedLiteral = elevatedGroups->Array.map(g => `'${g}'`)->Array.join(", ")
    `
  // ── owner scoping (generated) ──
  // Not read from ctx.args: a predicate deciding what the caller may see must
  // arrive on a channel the caller cannot name.
  const _oid = ctx.identity;
  const _osub = _oid == null ? null : _oid.sub;
  const _ogroups = (_oid != null && _oid.claims != null && _oid.claims['cognito:groups']) || [];
  const _oelevated = [${elevatedLiteral}];
  if (!(_osub == null || _ogroups.some(g => _oelevated.indexOf(g) >= 0))) {
    if (expression) expression += ' AND ';
    names['#owner'] = '${field}';
    values[':owner'] = _osub;
    expression += '#owner = :owner';
  }
  `
  }

/**
The same retirement predicate as `retiredGuardPreamble`, for a door that reads
with `Query` and so has a FilterExpression to put it in. Pushed into the read
rather than applied after it, or the page comes back short with nothing said
about why.

Appends to the `expression` / `names` / `values` the index templates already
build, so it composes with a caller's own filter arguments.
*/
let retiredFilterClause = (
  ~retiredField: option<string>,
  ~retiredValues: option<array<string>>,
  ~elevatedGroups: array<string>,
) =>
  switch retiredField {
  | None => ""
  | Some(field) =>
    let assignments = switch retiredValues {
    | None => `      values[':retiredFalse'] = false;
      expression += '(attribute_not_exists(#retired) OR #retired = :retiredFalse)';`
    | Some(states) =>
      let assigns =
        states
        ->Array.mapWithIndex((state, i) =>
          `      values[':retiredValue${Int.toString(i)}'] = '${state}';`
        )
        ->Array.join("\n")
      let comparisons =
        states
        ->Array.mapWithIndex((_, i) => `#retired <> :retiredValue${Int.toString(i)}`)
        ->Array.join(" AND ")
      `${assigns}
      expression += '(attribute_not_exists(#retired) OR (${comparisons}))';`
    }
    `${exemptPreamble(~elevatedGroups)}
  // ── retirement narrowing (generated) ──
  if (!(_exempt && ctx.args.includeRetired === true)) {
    if (expression) expression += ' AND ';
    names['#retired'] = '${field}';
${assignments}
  }
  `
  }

/**
A by-key read's response, refusing a row the caller does not own.

**Null, not an error.** The in-process platform answers `null` here, and a rule
enforced differently per transport is what owner scoping exists to avoid. An
error would also confirm the row exists to a caller who may not read it.
*/
let ownerScopedResultResponse = (
  ~ownerField: option<string>,
  ~elevatedGroups: array<string>,
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
) =>
  switch (ownerField, retiredField) {
  | (None, None) => resultResponseCode
  | _ =>
    let ownerPart = switch ownerField {
    // Takes the row it ignores: APPSYNC_JS type-checks the resolver, so a
  // zero-parameter stub called as `_owns(row)` is TS2554 ("Expected 0
  // arguments, but got 1") and AppSync rejects the whole resolver at create
  // time with "The code contains one or more errors". Only a door that emits
  // the call conditionally is safe with a bare `() => true`, and that is not a
  // property worth relying on across three templates.
  | None => "\n  const _owns = (row) => true;"
    | Some(field) =>
      `
  // ── owner scoping (generated) ──${ownerGuardPreamble(~ownerField=field, ~elevatedGroups)}`
    }
    let retiredPart = retiredGuardPreamble(
      ~retiredField,
      ~retiredValues,
      ~elevatedGroups,
      ~ownerScoped=ownerField->Option.isSome,
    )
    `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);${ownerPart}${retiredPart}
  return _owns(ctx.result)${retiredField->Option.isSome ? " && _live(ctx.result)" : ""} ? ctx.result : null;
}`
  }

/** The `queryByIdSort` counterpart — same rule, over the first row of a Query. */
let ownerScopedFirstResultResponse = (
  ~ownerField: option<string>,
  ~elevatedGroups: array<string>,
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
) =>
  switch (ownerField, retiredField) {
  | (None, None) => firstResultResponseCode
  | _ =>
    let ownerPart = switch ownerField {
    // Takes the row it ignores: APPSYNC_JS type-checks the resolver, so a
  // zero-parameter stub called as `_owns(row)` is TS2554 ("Expected 0
  // arguments, but got 1") and AppSync rejects the whole resolver at create
  // time with "The code contains one or more errors". Only a door that emits
  // the call conditionally is safe with a bare `() => true`, and that is not a
  // property worth relying on across three templates.
  | None => "\n  const _owns = (row) => true;"
    | Some(field) =>
      `
  // ── owner scoping (generated) ──${ownerGuardPreamble(~ownerField=field, ~elevatedGroups)}`
    }
    let retiredPart = retiredGuardPreamble(
      ~retiredField,
      ~retiredValues,
      ~elevatedGroups,
      ~ownerScoped=ownerField->Option.isSome,
    )
    `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);${ownerPart}${retiredPart}
  const _row = ctx.result.items[0] ?? null;
  return _owns(_row)${retiredField->Option.isSome ? " && _live(_row)" : ""} ? _row : null;
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

/** Pipeline function (NONE datasource): decodes global ID and stashes typeName + localId.

    Written without a `try`: APPSYNC_JS rejects try statements outright
    (`@aws-appsync/no-try`), and nothing is lost — `util.base64Decode` returns
    bytes rather than throwing on malformed input, so an unparseable id stashes
    both halves as null, which is what a guarded version reported anyway. */
let nodeDecodeGlobalId =
  `${importUtil}
export function request(ctx) {
  const decoded = util.base64Decode(ctx.args.id);
  const colonIdx = decoded.indexOf(':');
  const parsed = colonIdx > 0;
  ctx.stash.typeName = parsed ? decoded.substring(0, colonIdx) : null;
  ctx.stash.localId = parsed ? decoded.substring(colonIdx + 1) : null;
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
let getItemById = (
  ~ownerField: option<string>=?,
  ~elevatedGroups: array<string>=[],
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
) =>
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'GetItem',
    key: { id: util.dynamodb.toDynamoDB(ctx.args.id) }
  };
}
${ownerScopedResultResponse(~ownerField, ~elevatedGroups, ~retiredField?, ~retiredValues?)}
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
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
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
${ownerScopedFirstResultResponse(~ownerField, ~elevatedGroups, ~retiredField?, ~retiredValues?)}
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

// ---------------------------------------------------------------------------
// Paging a filtered read
// ---------------------------------------------------------------------------

/**
Rows a read may EXAMINE per page.

`Limit` applies before the FilterExpression, so reading `first` rows and returning
the survivors serves short — usually empty — pages under a selective filter. With
no loops in APPSYNC_JS the door reads wider instead and addresses the surplus by
position. 1 MB caps a page anyway, hence 1000; `filtered` is the JS expression
saying whether a filter was pushed down.
*/
let pageWindowBudget = (~filtered: string) =>
  `(${filtered} ? (_first > 1000 ? _first : 1000) : _first + _from)`

/**
Decodes `after` into the window it names (`t`, the token opening it) and the row's
index among that window's matches (`n`). Pre-window cursors carried
`{token, index}` naming the window that follows — position -1 of it.

`p` is the one-character tag naming which read the window belongs to (`s` Scan,
`q` the owner-index Query). Absent reads as `s`: every cursor minted before the
tag existed came off a Scan. Only a door with more than one read tests it — see
`cursorPathGuard`.
*/
let cursorDecode = (~args: string) => `
  let _window = null;
  let _from = 0;
  let _cursorPath = null;
  if (${args}.after != null && ${args}.after !== '') {
    const _c = JSON.parse(util.base64Decode(${args}.after));
    _window = (_c.t !== undefined ? _c.t : _c.token) ?? null;
    _from = _c.n !== undefined ? _c.n + 1 : 0;
    _cursorPath = _c.p ?? 's';
  }`

/**
Refuses a cursor minted on this door's other read. The two branches are selectable
by the SAME caller across requests — an active-role switch mid-pagination flips
`_exempt` — and a `nextToken` continues the operation that issued it, so replaying
one on the other branch answers a different question without saying so.

Expects `_cursorPath` from `cursorDecode` and `_exempt` from the owner preamble.
*/
let cursorPathGuard = `
  if (_cursorPath !== null && _cursorPath !== (_exempt ? 's' : 'q')) {
    util.error('This cursor belongs to a different read of this list; restart from the first page.', 'CursorPathMismatch');
  }`

/**
Cuts the requested page out of the returned window. Expects `items` (sorted, if the
door sorts) plus `_window` / `_from` from `cursorDecode`. `pathExpr` is the JS
expression naming which read minted these cursors, for a door that has two.
*/
let connectionPageResponse = (~pathExpr: option<string>=?) => {
  let tag = switch pathExpr {
  | None => ""
  | Some(e) => `, p: ${e}`
  }
  `
  const _first = ctx.args.first ?? 50;
  const _rest = items.slice(_from);
  const _page = _rest.slice(0, _first);
  const _more = _rest.length > _first;
  const _next = ctx.result?.nextToken ?? null;
  const _lastIndex = _page.length - 1;
  // A row's cursor names its own position. The last row of a page that closes its
  // window is the exception — no position follows it there, so it names the next
  // window, or resuming from it answers blank.
  const edges = _page.map((item, i) => ({
    node: item,
    cursor: util.base64Encode(JSON.stringify(
      (!_more && _next && i === _lastIndex)
        ? { t: _next, n: -1${tag} }
        : { t: _window, n: _from + i${tag} }
    )),
  }));
  // A window the filter emptied leaves no row to cut a cursor from; the token is
  // the window's, so a client can step past it rather than restart.
  const _boundary = _next ? util.base64Encode(JSON.stringify({ t: _next, n: -1${tag} })) : null;
  return {
    edges,
    pageInfo: {
      hasNextPage: _more || !!_next,
      hasPreviousPage: !!ctx.args.after,
      startCursor: edges.length > 0 ? edges[0].cursor : _boundary,
      endCursor: edges.length > 0 ? edges[edges.length - 1].cursor : _boundary,
    },
  };`
}

/**
The by-index door's response. Pages out of a read window exactly as
`listAllItemsConnection` does, and satisfies the `Connection!` the field has always
declared — returning `ctx.result` raw did not.
*/
let indexConnectionResponseCode = `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  const items = ctx.result?.items ?? [];${cursorDecode(~args="ctx.args")}${connectionPageResponse()}
}`

/** Refuses backward paging, for the reason `listAllItemsConnection` gives: the
cursor is DynamoDB's own continuation token, which only walks forward, so
`last`/`before` cannot be honoured, and handing back the forward page would answer
a different question without saying so. The arguments stay declared — one that
came and went with the index's shape would make every client feature-detect — and
the local backend refuses them with the same message. */
let indexBackwardPagingGuard = `
  if (args.before != null || args.last != null) {
    util.error('Backward pagination (last/before) is not supported on by-index connections; use first/after.', 'UnsupportedPagination');
  }`

/** Decodes the Relay `after` cursor back to the read window the response side
encoded, and sizes the window this read may examine. Mirrors
`listAllItemsConnection`'s request half. */
let indexCursorPreamble = `${cursorDecode(~args="args")}
  const _first = args.first ?? 50;`

// The arguments the by-index door declares, none of which is a column to match
// on. `includeRetired` is a request to lift a restriction and the rest are
// paging; left unlisted, the filter loop below turns each into a
// `contains(#arg, :arg)` against an attribute no row carries, and the door
// answers nothing.
let indexReservedArgs = `key === 'first' || key === 'after' || key === 'last' || key === 'before' || key === 'includeRetired' || key === 'limit' || key === 'nextToken' || key === 'forward'`

// AppSync JS runtime restrictions (APPSYNC_JS 1.0.0):
//   - No `for` loops (for/for-of/for-in all fail validation)
//   - No String() / .toString() — use '' + value instead
//   - Object.keys().forEach() works for iteration
let queryByIndexFiltered = (
  ~index: string,
  ~idField: string,
  ~ownerField: option<string>=?,
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
  ~elevatedGroups: array<string>=[],
) =>
  `${importUtil}
export function request(ctx) {
  const args = ctx.args;${indexBackwardPagingGuard}
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
    if (key === '${idField}' || ${indexReservedArgs}) return;
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
${ownerFilterClause(~ownerField, ~elevatedGroups)}${retiredFilterClause(~retiredField, ~retiredValues, ~elevatedGroups)}${indexCursorPreamble}
  const result = {
    operation: 'Query',
    query,
    index: '${index}',
    limit: ${pageWindowBudget(~filtered="expression")},
    nextToken: _window,
    scanIndexForward: (args.forward ?? true)
  };
  if (expression) {
    result.filter = { expression, expressionNames: names, expressionValues: util.dynamodb.toMapValues(values) };
  }
  return result;
}
${indexConnectionResponseCode}
`->Pulumi.Input.make

let queryByIndexSortFiltered = (
  ~index: string,
  ~idField: string,
  ~ownerField: option<string>=?,
  ~sortField: string,
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
  ~elevatedGroups: array<string>=[],
) =>
  `${importUtil}
export function request(ctx) {
  const args = ctx.args;${indexBackwardPagingGuard}
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
    if (key === '${idField}' || key === '${sortField}' || ${indexReservedArgs}) return;
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
${ownerFilterClause(~ownerField, ~elevatedGroups)}${retiredFilterClause(~retiredField, ~retiredValues, ~elevatedGroups)}${indexCursorPreamble}
  const result = {
    operation: 'Query',
    query,
    index: '${index}',
    limit: ${pageWindowBudget(~filtered="expression")},
    nextToken: _window,
    scanIndexForward: (args.forward ?? true)
  };
  if (expression) {
    result.filter = { expression, expressionNames: names, expressionValues: util.dynamodb.toMapValues(values) };
  }
  return result;
}
${indexConnectionResponseCode}
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
Scan behind `filter: {search?, searchPrefix?, ids?, <field>Eq?, <field>From?,
<field>To?}` and `orderBy: {field, direction}`. `search` / `searchPrefix` become
`contains` / `begins_with` on `labelField` (case-sensitive — a case-insensitive
match wants a lowercased projected column); `ids` becomes `#id IN (…)`; the
per-field forms become `=` / `>=` / `<=`.

`orderBy` sorts in the JS runtime over the read window, not globally: Scan returns
items in indeterminate order and `ScanIndexForward` is Query-only. Empty and null
filter values mean "no filter", as they do in-memory.

With `ownerIndex` the door has **two** reads against the same data source, chosen
by whether the caller is exempt from owner scoping: a Query on the derived
`@owner` index for a scoped caller, the Scan above for everyone else. A user
`filter` still lands in a FilterExpression on top of the Query's key condition, so
a scoped caller searching their own rows can still get a short page — but bounded
by their row count rather than the table's.
*/
let listAllItemsConnection = (
  ~labelField: string,
  ~filterFields: array<string>=[],
  ~rangeFields: array<string>=[],
  ~sortFields: array<string>=[],
  // An always-on `attribute_exists(#<attr>)` clause, for a read model whose table
  // co-hosts bookkeeping rows written outside the projection (the Plugins admin RM's
  // `deploy-schema:*` / `plugin-info:*` rows carry no `name`). Those rows resolve
  // non-null fields to null and take the whole Connection with them.
  ~requireAttribute: option<string>=?,
  // The state's `@owner` field and the groups exempt from scoping. Baked in
  // because no Lambda sits in this path to read a value at request time, so the
  // elevated-group list changes only on redeploy.
  ~ownerField: option<string>=?,
  ~elevatedGroups: array<string>=[],
  // The state's `@retired` field, when it declares one. Baked in for the same
  // reason `ownerField` is: there is no Lambda in this path to read it at
  // request time.
  ~retiredField: option<string>=?,
  // The states that retire the row, for the state form of the annotation.
  // Absent is the boolean form, where the value is always `true`.
  ~retiredValues: option<array<string>>=?,
  // The index `@owner` derives, and its sort key. Present turns the owner
  // predicate from a post-read sieve into a key condition for a scoped caller.
  ~ownerIndex: option<string>=?,
  ~ownerIndexSortField: option<string>=?,
) => {
  // The Query branch needs `ownerField` to key on; an index without one would
  // have nothing to name in the key condition.
  let ownerIndex = ownerField->Option.isSome ? ownerIndex : None
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
  //
  // Emitted in BOTH halves of the resolver when an owner index is in play: the
  // response has to know which read minted the cursors it hands out, and that is
  // the same question.
  let ownerIdentityPreamble = {
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
  const _exempt = _sub == null || _groups.some(g => _elevated.indexOf(g) >= 0);`
  }
  let ownerClause = switch (ownerField, ownerIndex) {
  | (None, _) => ""
  // With an index the predicate is the Query's key condition, so nothing is
  // pushed into the filter — and nothing may be: an expressionName the filter
  // never references is a ValidationException, not a harmless extra.
  | (Some(_), Some(_)) => ownerIdentityPreamble
  | (Some(field), None) =>
    `${ownerIdentityPreamble}
  if (!_exempt) {
    names['#owner'] = '${field}';
    values[':owner'] = util.dynamodb.toDynamoDB(_sub);
    parts.push('#owner = :owner');
  }`
  }
  // ── retirement narrowing (generated) ──
  // Reuses `_exempt` when the owner clause computed it; either clause may be the
  // only one present. `includeRetired` IS read from ctx.args, unlike the owner
  // predicate — it asks to lift a restriction rather than naming rows, and is
  // honoured only inside `_exempt`.
  //
  // `attribute_not_exists OR = false` rather than `<> true`, because `<>` does not
  // match a missing attribute and the view would empty out the day the annotation
  // lands. The state form compares `<>` against the retiring state under the same
  // guard.
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
  // When the Query branch already ordered on the index's own sort key, the page
  // arrives globally ordered and re-sorting it here is the one way to break that
  // order — a sort over a page is not a sort over the caller's rows.
  let sortGuard = switch (ownerIndex, ownerIndexSortField) {
  | (Some(_), Some(_)) => "!_indexOrdered && "
  | _ => ""
  }
  let sortBlock = if sortFields->Array.length == 0 {
    ""
  } else {
    // APPSYNC_JS 1.0.0 forbids comparator sorts, loops, recursion and ++/--, so
    // this is a schwartzian transform: encode each item as `<sortKey>\x01<json>`,
    // default-sort lexicographically, reverse for DESC, decode. Numbers are
    // zero-padded so lex order matches numeric order for non-negative values;
    // nulls split out and append to the end either way.
    `
  // Per-page sort (Scan returns items in indeterminate order; ScanIndexForward
  // does not apply to Scan). Global ordering across pages requires v1.5 index
  // promotion; @scanSort is per-page even then.
  const orderBy = ctx.args.orderBy;
  const sortFields = [${sortFieldsLiteral}];
  if (${sortGuard}orderBy && orderBy.field && sortFields.indexOf(orderBy.field) >= 0) {
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
  // Did the Query branch order this page itself? Answered the same way in both
  // halves, because both need it: the request to set `scanIndexForward`, the
  // response to leave an already-ordered page alone.
  let indexOrderedExpr = switch (ownerIndex, ownerIndexSortField) {
  | (Some(_), Some(sf)) =>
    `!_exempt && !!(ctx.args.orderBy && ctx.args.orderBy.field === '${sf}')`
  | _ => "false"
  }
  // The two reads, chosen by the same test that used to choose a predicate.
  // Both target the one data source the resolver is attached to, so this is a
  // branch inside one resolver — no second field, no second data source, no
  // client change.
  let requestOperation = switch (ownerField, ownerIndex) {
  | (Some(field), Some(index)) => `
  const _indexOrdered = ${indexOrderedExpr};
  const req = _exempt
    ? {
        operation: 'Scan',
        limit: ${pageWindowBudget(~filtered="parts.length > 0")},
        nextToken: _window,
      }
    : {
        operation: 'Query',
        index: '${index}',
        query: {
          expression: '#owner = :owner',
          expressionNames: { '#owner': '${field}' },
          expressionValues: { ':owner': util.dynamodb.toDynamoDB(_sub) },
        },
        limit: ${pageWindowBudget(~filtered="parts.length > 0")},
        nextToken: _window,
        scanIndexForward: !(_indexOrdered && ctx.args.orderBy.direction === 'DESC'),
      };`
  | _ => `
  const req = {
    operation: 'Scan',
    limit: ${pageWindowBudget(~filtered="parts.length > 0")},
    nextToken: _window,
  };`
  }
  // Only a door with two reads tests the tag, and only that door stamps one.
  let requestPathGuard = ownerIndex->Option.isSome ? cursorPathGuard : ""
  let responsePathPreamble = switch ownerIndex {
  | None => ""
  | Some(_) => `${ownerIdentityPreamble}
  const _path = _exempt ? 's' : 'q';
  const _indexOrdered = ${indexOrderedExpr};`
  }
  let pageResponse = switch ownerIndex {
  | None => connectionPageResponse()
  | Some(_) => connectionPageResponse(~pathExpr="_path")
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
${cursorDecode(~args="ctx.args")}${requestPathGuard}
  const _first = ctx.args.first ?? 50;${requestOperation}
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
  let items = ctx.result?.items ?? [];${responsePathPreamble}${sortBlock}${cursorDecode(
      ~args="ctx.args",
    )}${pageResponse}
}
`->Pulumi.Input.make
}

// ---------------------------------------------------------------------------
// DynamoDB nested resolvers — resolve linked item(s) by ID
// ---------------------------------------------------------------------------

/**
The response of a cross-table field (`@resolves`) over a Query-shaped read.

The narrowing is the TARGET's, not the declaring view's — the row is the target's,
so it answers with the same `_owns` / `_live` guards its by-key doors use. A
nested field takes no `includeRetired`, so a retired row never travels through
one; `{list}Refs` + `@namedWhenRetired` is that door.
*/
let resolvedFieldResponse = (
  ~multi: bool,
  ~ownerField: option<string>,
  ~elevatedGroups: array<string>,
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
) =>
  switch (ownerField, retiredField) {
  | (None, None) => multi ? resultListResponseCode : firstResultResponseCode
  | _ =>
    let ownerPart = switch ownerField {
    // Takes the row it ignores, for the reason `ownerScopedResponse` gives: a
    // zero-parameter stub called with one argument is a TS2554 the APPSYNC_JS
    // type-checker rejects at resolver-create time.
    | None => "\n  const _owns = (row) => true;"
    | Some(field) =>
      `
  // ── owner scoping (generated) ──${ownerGuardPreamble(~ownerField=field, ~elevatedGroups)}`
    }
    let retiredPart = retiredGuardPreamble(
      ~retiredField,
      ~retiredValues,
      ~elevatedGroups,
      ~ownerScoped=ownerField->Option.isSome,
    )
    let live = retiredField->Option.isSome ? " && _live(_row)" : ""
    let body = multi
      ? `  return (ctx.result.items ?? []).filter(_row => _owns(_row)${live});`
      : `  const _row = ctx.result.items[0] ?? null;\n  return _owns(_row)${live} ? _row : null;`
    `
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);${ownerPart}${retiredPart}
${body}
}`
  }

let resolveId = (~sourceIdField: string, ~response: string=firstResultResponseCode) =>
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
${response}
`->Pulumi.Input.make

let resolveIdSort = (
  ~sourceIdField: string,
  ~sourceSortField: string,
  ~targetSortField: string,
  ~response: string=firstResultResponseCode,
) =>
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
${response}
`->Pulumi.Input.make

let resolveIdSortArgument = (
  ~sourceIdField: string,
  ~sourceSortArgument: string,
  ~targetSortField: string,
  ~response: string=firstResultResponseCode,
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
${response}
`->Pulumi.Input.make

// ---------------------------------------------------------------------------
// DynamoDB nested resolvers — resolve by index
// ---------------------------------------------------------------------------

let resolveIdByIndex = (
  ~index: string,
  ~sourceIdField: string,
  ~targetIdField: string,
  ~response: string=firstResultResponseCode,
) =>
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
${response}
`->Pulumi.Input.make

let resolveIdByIndexSort = (
  ~index: string,
  ~sourceIdField: string,
  ~sourceSortField: string,
  ~targetIdField: string,
  ~targetSortField: string,
  ~response: string=firstResultResponseCode,
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
${response}
`->Pulumi.Input.make

let resolveIdByIndexSortArgument = (
  ~index: string,
  ~sourceIdField: string,
  ~sourceSortArgument: string,
  ~targetIdField: string,
  ~targetSortField: string,
  ~response: string=firstResultResponseCode,
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
${response}
`->Pulumi.Input.make

/** `@resolvesMany` — the parent's id array batch-read from the target's table.

    A plain string, because BatchGetItem's `tables` map keys on the literal name,
    which the adapter interpolates via `Pulumi.Output.apply`. Same shape and
    guards as `batchGetItemsByIds`; missing ids come back null and are dropped, so
    the field is shorter rather than null-holed. */
let resolveIds = (
  ~idsField: string,
  ~sortField: option<string>,
  ~ownerField: option<string>=?,
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
  ~elevatedGroups: array<string>=[],
) => (tableName: string) => {
  let keysCode = switch sortField {
  | Some(sf) =>
    `id => ({ id: util.dynamodb.toString(id.id), ${sf}: util.dynamodb.toString(id.${sf}) })`
  | None => `id => ({ id: util.dynamodb.toString(id) })`
  }
  `${importUtil}
import { runtime } from '@aws-appsync/utils';
export function request(ctx) {
  const idList = ctx.source.${idsField} ?? [];
  if (idList.length === 0) return runtime.earlyReturn([]);
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
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);${switch ownerField {
    | None => ""
    | Some(field) => ownerGuardPreamble(~ownerField=field, ~elevatedGroups)
    }}${retiredGuardPreamble(
      ~retiredField,
      ~retiredValues,
      ~elevatedGroups,
      ~ownerScoped=ownerField->Option.isSome,
    )}
  return (ctx.result?.data?.['${tableName}'] ?? []).filter(item =>
    item !== null${ownerField->Option.isSome ? " && _owns(item)" : ""}${retiredField->Option.isSome
      ? " && _live(item)"
      : ""});
}
`
}

/** Batched-by-ids — reads `ctx.args.ids: [String!]!` through one BatchGetItem.
    Missing ids drop out; empty input short-circuits without hitting DDB. The
    table name is interpolated at deploy time, since BatchGetItem's `tables` map
    keys on the literal. Single-key tables only. */
let batchGetItemsByIds = (
  ~ownerField: option<string>=?,
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
  ~elevatedGroups: array<string>=[],
) => (tableName: string) =>
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
  // BatchGetItem returns null for keys that don't exist, preserving index
  // correspondence. The SDL declares \`[T!]!\`, so one missing id would null the
  // whole field — drop them and return what was found.
  // The owner and retirement guards the list pushes into a FilterExpression,
  // applied after the read because BatchGetItem has none to push into. A row the
  // caller does not own is dropped rather than refused, for the reason the
  // single-key door answers null: distinguishing "not yours" from "not there"
  // would make this door an oracle for which ids exist.${switch ownerField {
    | None => ""
    | Some(field) => ownerGuardPreamble(~ownerField=field, ~elevatedGroups)
    }}${retiredGuardPreamble(
      ~retiredField,
      ~retiredValues,
      ~elevatedGroups,
      ~ownerScoped=ownerField->Option.isSome,
    )}
  return (ctx.result?.data?.['${tableName}'] ?? []).filter(item =>
    item !== null${ownerField->Option.isSome ? " && _owns(item)" : ""}${retiredField->Option.isSome
      ? " && _live(item)"
      : ""});
}
`

/** The reference door — `{list}Refs(ids)`: what a caller holding a pointer to a
    row may learn about it, and nothing else.

    The same BatchGetItem as `batchGetItemsByIds`, projected to
    `{id, label, retired, retiredState}` by the SDL type, so the response builds
    three fields rather than deciding what to withhold. `namedWhenRetired` decides
    a retired row: false drops it, true names it. The owner rule applies either
    way — that is not what the annotation lifts. */
let refsByIds = (
  ~labelField: string,
  ~retiredField: option<string>,
  ~retiredValues: option<array<string>>,
  ~namedWhenRetired: bool,
  ~ownerField: option<string>=?,
  ~elevatedGroups: array<string>=[],
) => (tableName: string) => {
  let ownerGuard = switch ownerField {
  // Takes the row it ignores: APPSYNC_JS type-checks the resolver, so a
  // zero-parameter stub called as `_owns(row)` is TS2554 ("Expected 0
  // arguments, but got 1") and AppSync rejects the whole resolver at create
  // time with "The code contains one or more errors". Only a door that emits
  // the call conditionally is safe with a bare `() => true`, and that is not a
  // property worth relying on across three templates.
  | None => "\n  const _owns = (row) => true;"
  | Some(field) => ownerGuardPreamble(~ownerField=field, ~elevatedGroups)
  }
  // Retirement, in the vocabulary the row itself uses: a member test for the
  // state form, truthiness for the boolean one. Absent keeps the row live, which
  // is what a row written before the annotation is.
  let retiredExpr = switch (retiredField, retiredValues) {
  | (None, _) => "false"
  | (Some(f), Some(values)) =>
    let literal = values->Array.map(v => `'${v}'`)->Array.join(", ")
    `[${literal}].indexOf(row['${f}']) >= 0`
  | (Some(f), None) => `row['${f}'] === true`
  }
  // Only the state form has a state to name, and only a retired row reports one:
  // this door names rows, it does not publish a lifecycle column to callers the
  // list withholds.
  let stateExpr = switch (retiredField, retiredValues) {
  | (Some(f), Some(_)) => `_retired(row) ? (row['${f}'] ?? null) : null`
  | _ => "null"
  }
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
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);${ownerGuard}
  const _retired = (row) => ${retiredExpr};
  const _namesRetired = ${namedWhenRetired ? "true" : "false"};
  return (ctx.result?.data?.['${tableName}'] ?? [])
    .filter(row => row !== null && _owns(row))
    .filter(row => _namesRetired || !_retired(row))
    .map(row => ({
      id: row.id,
      label: row['${labelField}'] ?? row.id,
      retired: _retired(row),
      retiredState: ${stateExpr},
    }));
}
`
}

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
