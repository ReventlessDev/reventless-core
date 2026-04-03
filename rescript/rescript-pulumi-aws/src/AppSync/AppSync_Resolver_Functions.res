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
// DynamoDB read — by primary key
// ---------------------------------------------------------------------------

let getItemById =
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'GetItem',
    key: { id: util.dynamodb.toDynamoDB(ctx.args.id) }
  };
}
${resultResponseCode}
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

let queryByIdSort = (sortField: string) =>
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
${firstResultResponseCode}
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
  for (const [key, value] of Object.entries(args)) {
    if (key === '${idField}' || key === 'limit' || key === 'nextToken' || key === 'forward') continue;
    if (value == null || value === '') continue;
    if (expression) expression += ' AND';
    if (key === 'hideDeleted') {
      if (value === true) {
        expression += ' #deleted = :false';
        names['#deleted'] = 'deleted';
        values[':false'] = false;
      }
    } else if (Array.isArray(value)) {
      names['#' + key] = key;
      for (const item of value) {
        if (expression && !expression.endsWith('AND')) expression += ' AND';
        expression += ' contains(#' + key + ', :' + item + ')';
        values[':' + item] = String(item);
      }
    } else {
      expression += ' contains(#' + key + ', :' + key + ')';
      names['#' + key] = key;
      values[':' + key] = String(value);
    }
  }
  return {
    operation: 'Query',
    query,
    ...(expression ? { filter: { expression, expressionNames: names, expressionValues: util.dynamodb.toMapValues(values) } } : {}),
    index: '${index}',
    limit: (args.limit ?? 50),
    nextToken: (args.nextToken ?? null),
    scanIndexForward: (args.forward ?? true)
  };
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
  for (const [key, value] of Object.entries(args)) {
    if (key === '${idField}' || key === '${sortField}' || key === 'limit' || key === 'nextToken' || key === 'forward') continue;
    if (value == null || value === '') continue;
    if (expression) expression += ' AND';
    if (key === 'hideDeleted') {
      if (value === true) {
        expression += ' #deleted = :false';
        names['#deleted'] = 'deleted';
        values[':false'] = false;
      }
    } else if (Array.isArray(value)) {
      names['#' + key] = key;
      for (const item of value) {
        if (expression && !expression.endsWith('AND')) expression += ' AND';
        expression += ' contains(#' + key + ', :' + item + ')';
        values[':' + item] = String(item);
      }
    } else {
      expression += ' contains(#' + key + ', :' + key + ')';
      names['#' + key] = key;
      values[':' + key] = String(value);
    }
  }
  return {
    operation: 'Query',
    query,
    ...(expression ? { filter: { expression, expressionNames: names, expressionValues: util.dynamodb.toMapValues(values) } } : {}),
    index: '${index}',
    limit: (args.limit ?? 50),
    nextToken: (args.nextToken ?? null),
    scanIndexForward: (args.forward ?? true)
  };
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
  return {
    operation: 'Invoke',
    payload: {
      command: '${command}',
      arguments: ctx.args,
      meta: {
        ip: ctx.identity.sourceIp,
        user: ctx.identity.username,
        info: ctx.info.parentTypeName + '.' + ctx.info.fieldName
      },
      identity: {
        userId: ctx.identity.sub,
        username: ctx.identity.username,
        groups: ctx.identity.claims['cognito:groups'] ?? [],
        claims: ctx.identity.claims,
        provider: 'Cognito'
      }
    }
  };
}
${resultResponseCode}
`->Pulumi.Input.make

/** Invoke a DCB Lambda. `tag` is the DCB entity tag. */
let invokeDcbMutation = (tag: string) =>
  `${importUtil}
export function request(ctx) {
  return {
    operation: 'Invoke',
    payload: {
      command: '${tag}',
      arguments: ctx.args,
      meta: {
        ip: ctx.identity.sourceIp,
        user: ctx.identity.username,
        info: ctx.info.parentTypeName + '.' + ctx.info.fieldName
      },
      identity: {
        userId: ctx.identity.sub,
        username: ctx.identity.username,
        groups: ctx.identity.claims['cognito:groups'] ?? [],
        claims: ctx.identity.claims,
        provider: 'Cognito'
      }
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
  const groups = ctx.identity.claims['cognito:groups'] ?? [];
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
