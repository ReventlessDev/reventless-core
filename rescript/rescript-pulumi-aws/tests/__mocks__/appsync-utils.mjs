/** Minimal mock of @aws-appsync/utils for unit testing resolver functions. */

export const util = {
  dynamodb: {
    toDynamoDB: val => ({ S: String(val) }),
    toString: val => ({ S: String(val) }),
    toNumber: val => ({ N: String(val) }),
    toBoolean: val => ({ BOOL: val }),
    toNull: () => ({ NULL: true }),
    toList: items => ({ L: items }),
    toMapValues: obj => Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, { S: String(v) }])),
    toStringSet: arr => ({ SS: arr }),
    toNumberSet: arr => ({ NS: arr.map(String) }),
  },
  error: (msg, type) => { throw Object.assign(new Error(msg), { errorType: type }) },
  unauthorized: () => { throw new Error('Unauthorized') },
  defaultIfNull: (val, def) => (val === null || val === undefined ? def : val),
  defaultIfNullOrBlank: (val, def) => (!val || (typeof val === 'string' && val.trim() === '') ? def : val),
  isNull: val => val === null || val === undefined,
  isNullOrBlank: val => !val || (typeof val === 'string' && val.trim() === ''),
  isList: val => Array.isArray(val),
}

export const runtime = {
  earlyReturn: val => { throw Object.assign(new Error('earlyReturn'), { earlyReturnValue: val }) },
}
