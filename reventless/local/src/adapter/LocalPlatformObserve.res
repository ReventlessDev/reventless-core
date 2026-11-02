// What the platform API and the platform MCP server offer a tool that watches
// this platform: every event of every log newest first (`Platform_EventLog`),
// the log level while running (`Platform_LogLevels`, `Platform_SetLogLevel`),
// the log feed and the event tap as subscriptions (`Platform_LogAppended`,
// `Platform_EventAppended`), the metrics counted since start (`Platform_Metrics`),
// and the MCP resources `platform/logs/recent`, `platform/events` and
// `platform/metrics`.
//
// Every field here is admin-checked, also when the platform serves one API for
// both, where nothing else would check it.

module Logger = ReventlessCore.Logger
module GQL = ReventlessGraphqlServer.GraphQL_ServerInstance

// ─── SDL ─────────────────────────────────────────────────────────────────────

let eventLogTypes = [
  "scalar AWSJSON",
  `input Platform_EventLogFilter {
  plugins: [String!]
  logs: [String!]
  eventTypes: [String!]
  entityId: String
  tagKey: String
  tagValue: String
  msgId: String
  correlationId: String
  causationId: String
  user: String
  timeFrom: String
  timeTo: String
}`,
  `type Platform_EventLogTag {
  key: String!
  value: String!
}`,
  `type Platform_EventLogRecord {
  plugin: String
  log: String!
  position: String!
  eventType: String!
  entityId: String
  tags: [Platform_EventLogTag!]!
  payload: AWSJSON!
  meta: AWSJSON!
  recordedAt: String!
}`,
  `type Platform_EventLogEdge {
  node: Platform_EventLogRecord!
  cursor: String!
}`,
  `type Platform_EventLogPageInfo {
  hasNextPage: Boolean!
  endCursor: String
}`,
  `type Platform_EventLogConnection {
  edges: [Platform_EventLogEdge!]!
  pageInfo: Platform_EventLogPageInfo!
}`,
]

let logLevelTypes = [
  `enum Platform_LogLevel {
  DEBUG
  INFO
  WARN
  ERROR
}`,
  `type Platform_LogLevelSetting {
  plugin: String
  comp: String
  level: Platform_LogLevel!
}`,
  `type Platform_LogLevels {
  base: Platform_LogLevel
  settings: [Platform_LogLevelSetting!]!
}`,
]

let metricTypes = [
  `type Platform_MetricCount {
  metric: String!
  plugin: String!
  slice: String!
  unit: String!
  count: Int!
  sum: Float!
  lastAt: String!
  perMinute: [Int!]!
}`,
]

let feedTypes = [
  `input Platform_FeedFilter {
  plugins: [String!]
  level: Platform_LogLevel
  components: [String!]
  eventTypes: [String!]
  correlationId: String
}`,
]

let eventLogField = "Platform_EventLog"
let logLevelsField = "Platform_LogLevels"
let setLogLevelField = "Platform_SetLogLevel"
let metricsField = "Platform_Metrics"

let queryFields = [
  `  ${eventLogField}(filter: Platform_EventLogFilter, first: Int, after: String): Platform_EventLogConnection!`,
  `  ${logLevelsField}: Platform_LogLevels!`,
  `  ${metricsField}(plugins: [String!]): [Platform_MetricCount!]!`,
]

let logAppendedField = "Platform_LogAppended"
let eventAppendedField = "Platform_EventAppended"

// Each value is one line of the feed as JSON: a log record (the log feed's line),
// an event tap line without its sentinel prefix, or `{"kind":"skipped","count":N}`.
let subscriptionFields = [
  `  ${logAppendedField}(filter: Platform_FeedFilter): AWSJSON!`,
  `  ${eventAppendedField}(filter: Platform_FeedFilter): AWSJSON!`,
]

let mutationFields = [
  `  ${setLogLevelField}(plugin: String, comp: String, level: Platform_LogLevel): Platform_LogLevels!`,
]

// ─── Resolvers ───────────────────────────────────────────────────────────────

let arg = (args: JSON.t, key: string): option<JSON.t> =>
  args->JSON.Decode.object->Option.flatMap(d => d->Dict.get(key))

let pageJson = (page: LocalEventLogRead.page): JSON.t =>
  Dict.fromArray([
    (
      "edges",
      page.edges
      ->Array.map(((record, cursor)) =>
        Dict.fromArray([
          ("node", LocalEventLogRead.recordToJson(record)),
          ("cursor", JSON.Encode.string(cursor)),
        ])->JSON.Encode.object
      )
      ->JSON.Encode.array,
    ),
    (
      "pageInfo",
      Dict.fromArray([
        ("hasNextPage", JSON.Encode.bool(page.hasNextPage)),
        ("endCursor", page.endCursor->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
      ])->JSON.Encode.object,
    ),
  ])->JSON.Encode.object

let eventLog: GQL.resolverFn = async (_root, args, _ctx) => {
  let page = await LocalEventLogRead.read(
    ~filter=LocalEventLogRead.filterOfJson(arg(args, "filter")),
    ~first=?arg(args, "first")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt),
    ~after=?arg(args, "after")->Option.flatMap(JSON.Decode.string),
  )
  pageJson(page)
}

let levelOfWire = (s: string): option<Logger.level> =>
  switch s {
  | "DEBUG" => Some(Debug)
  | "INFO" => Some(Info)
  | "WARN" => Some(Warn)
  | "ERROR" => Some(Error)
  | _ => None
  }

let levelsJson = (): JSON.t =>
  Dict.fromArray([
    (
      "base",
      Logger.effectiveMin()->Option.mapOr(JSON.Encode.null, l =>
        l->Logger.levelLabel->JSON.Encode.string
      ),
    ),
    (
      "settings",
      Logger.levelSettings()
      ->Array.map(s =>
        [("level", s.level->Logger.levelLabel->JSON.Encode.string)]
        ->Array.concat(s.plugin->Option.mapOr([], p => [("plugin", JSON.Encode.string(p))]))
        ->Array.concat(s.comp->Option.mapOr([], c => [("comp", JSON.Encode.string(c))]))
        ->Dict.fromArray
        ->JSON.Encode.object
      )
      ->JSON.Encode.array,
    ),
  ])->JSON.Encode.object

let logLevels: GQL.resolverFn = async (_root, _args, _ctx) => levelsJson()

let log = Logger.fromEnv()

let setLogLevel: GQL.resolverFn = async (_root, args, _ctx) => {
  let plugin = arg(args, "plugin")->Option.flatMap(JSON.Decode.string)
  let comp = arg(args, "comp")->Option.flatMap(JSON.Decode.string)
  let level = arg(args, "level")->Option.flatMap(JSON.Decode.string)->Option.flatMap(levelOfWire)
  Logger.setLevel(~plugin?, ~comp?, level)
  let scope = switch (plugin, comp) {
  | (Some(p), Some(c)) => `${c} of ${p}`
  | (None, Some(c)) => c
  | (Some(p), None) => p
  | (None, None) => "every line"
  }
  log.info(
    ~comp="Platform",
    switch level {
    | Some(l) => `log level for ${scope} set to ${l->Logger.levelLabel}`
    | None => `log level for ${scope} cleared`
    },
  )
  levelsJson()
}

// ─── The feeds as subscriptions ──────────────────────────────────────────────
// A subscriber is one more listener on the feed, with the same filter, bound and
// `skipped` line; its sink hands lines to the subscription as the client takes
// them, and asks the feed to wait while the client is behind.

let feedFilterOf = (json: option<JSON.t>): LocalFeed.filter => {
  let d = json->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
  let a = k =>
    d
    ->Dict.get(k)
    ->Option.flatMap(JSON.Decode.array)
    ->Option.map(items => items->Array.filterMap(JSON.Decode.string))
  {
    plugins: ?a("plugins"),
    level: ?(d->Dict.get("level")->Option.flatMap(JSON.Decode.string)->Option.flatMap(levelOfWire)),
    components: ?a("components"),
    eventTypes: ?a("eventTypes"),
    correlationId: ?(d->Dict.get("correlationId")->Option.flatMap(JSON.Decode.string)),
  }
}

type asyncIterable
type iteratorResult = {done: bool, value?: JSON.t}

let makeAsyncIterable: (
  unit => promise<iteratorResult>,
  unit => promise<iteratorResult>,
) => asyncIterable = %raw(`function (next, ret) {
  return { next, return: ret, [Symbol.asyncIterator]() { return this } }
}`)

// How many lines a subscription holds for its client before the feed is asked to
// wait; beyond that the feed's own bounded queue takes over.
let subscriptionWindow = 256

let tapSentinel = "@@RVLESS_EVT@@ "

/** A line as the subscription delivers it: JSON, without the tap's prefix. */
let lineToJson = (line: string): JSON.t => {
  let body =
    line->String.startsWith(tapSentinel)
      ? line->String.slice(~start=tapSentinel->String.length, ~end=line->String.length)
      : line
  try body->JSON.parseOrThrow catch {
  | _ => JSON.Encode.string(line)
  }
}

let feedSubscription = (feed: LocalFeed.t, ~filter: LocalFeed.filter): asyncIterable => {
  let pending: array<JSON.t> = []
  let waiting: ref<option<iteratorResult => unit>> = ref(None)
  let drainers: ref<array<unit => unit>> = ref([])
  let closed = ref(false)
  let sink: LocalFeed.sink = {
    write: line => {
      let value = lineToJson(line)
      switch waiting.contents {
      | Some(resolve) =>
        waiting := None
        resolve({done: false, value})
      | None => pending->Array.push(value)
      }
      pending->Array.length < subscriptionWindow
    },
    onceDrain: f => drainers := drainers.contents->Array.concat([f]),
    buffered: () => pending->Array.reduce(0, (sum, v) => sum + v->JSON.stringify->String.length),
    close: () => closed := true,
  }
  let unsubscribe = feed->LocalFeed.subscribe(~filter, sink)
  let next = () =>
    switch pending->Array.shift {
    | Some(value) =>
      if pending->Array.length < subscriptionWindow / 2 {
        let toCall = drainers.contents
        drainers := []
        toCall->Array.forEach(f => f())
      }
      Promise.resolve({done: false, value})
    | None if closed.contents => Promise.resolve({done: true})
    | None => Promise.make((resolve, _) => waiting := Some(resolve))
    }
  let return = () => {
    closed := true
    unsubscribe()
    waiting.contents->Option.forEach(resolve => resolve({done: true}))
    waiting := None
    Promise.resolve({done: true})
  }
  makeAsyncIterable(next, return)
}

type subscriptionResolver = {
  subscribe: GQL.resolverFn,
  resolve: JSON.t => JSON.t,
}
external toResolverFn: subscriptionResolver => GQL.resolverFn = "%identity"
external fromAsyncIterable: asyncIterable => JSON.t = "%identity"

let feedField = (feed: LocalFeed.t): GQL.resolverFn =>
  toResolverFn({
    subscribe: Auth_GraphqlContext.requireGroup(~group=Reventless.Role.adminGroup(), async (
      _root,
      args,
      _ctx,
    ) => feedSubscription(feed, ~filter=feedFilterOf(arg(args, "filter")))->fromAsyncIterable),
    resolve: payload => payload,
  })

/** The metrics counted since the platform started, of the given plugins or of every one:
    per metric and slice, how often, the sum of their values, and the last 60 minutes. */
let metrics: GQL.resolverFn = async (_root, args, _ctx) =>
  LocalMetrics.read(
    ~plugins=?arg(args, "plugins")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.map(a => a->Array.filterMap(JSON.Decode.string)),
  )

let adminOnly = (resolvers: array<(string, GQL.resolverFn)>): dict<GQL.resolverFn> =>
  resolvers
  ->Array.map(((name, resolver)) => (
    name,
    Auth_GraphqlContext.requireGroup(~group=Reventless.Role.adminGroup(), resolver),
  ))
  ->Dict.fromArray

/** Registers the fields on the platform API. */
let registerGraphQL = (server: GQL.t) => {
  server.registerTypes(
    ~sdlTypes=eventLogTypes
    ->Array.concat(logLevelTypes)
    ->Array.concat(metricTypes)
    ->Array.concat(feedTypes),
  )
  server.registerQueries(
    ~sdlFields=queryFields,
    ~resolvers=adminOnly([
      (eventLogField, eventLog),
      (logLevelsField, logLevels),
      (metricsField, metrics),
    ]),
  )
  server.registerMutations(
    ~sdlFields=mutationFields,
    ~resolvers=adminOnly([(setLogLevelField, setLogLevel)]),
  )
  server.registerSubscriptions(
    ~sdlFields=subscriptionFields,
    ~resolvers=Dict.fromArray([
      (logAppendedField, feedField(LocalLogFeed.feed)),
      (eventAppendedField, feedField(LocalEventTap.feed)),
    ]),
  )
}

// ─── MCP resources ───────────────────────────────────────────────────────────

let recentLogsUri = "platform/logs/recent"
let eventsUri = "platform/events"
let metricsUri = "platform/metrics"

@val external decodeURIComponent: string => string = "decodeURIComponent"

/** The query string of a resource URI, decoded. */
let queryOf = (uri: string): dict<string> => {
  let params = Dict.make()
  switch uri->String.split("?")->Array.get(1) {
  | None => ()
  | Some(qs) =>
    qs
    ->String.split("&")
    ->Array.forEach(pair => {
      let decode = s =>
        try decodeURIComponent(s->String.replaceAll("+", " ")) catch {
        | _ => s
        }
      switch pair->String.indexOf("=") {
      | -1 => ()
      | i =>
        params->Dict.set(
          decode(pair->String.slice(~start=0, ~end=i)),
          decode(pair->String.slice(~start=i + 1, ~end=pair->String.length)),
        )
      }
    })
  }
  params
}

let listOf = (q: dict<string>, key: string): option<array<string>> =>
  q
  ->Dict.get(key)
  ->Option.map(v => v->String.split(",")->Array.map(String.trim)->Array.filter(s => s != ""))

let intOf = (q: dict<string>, key: string): option<int> =>
  q->Dict.get(key)->Option.flatMap(v => Int.fromString(v))

let resourceResult = (~uri: string, json: JSON.t): McpSdk.readResourceResult => {
  McpSdk.contents: [{McpSdk.uri, text: json->JSON.stringify}],
}

/** `platform/logs/recent?plugins=a,b&level=warn&components=c&correlationId=x&limit=n`:
    the recent records the filter selects, oldest first, at most `limit`
    (default 200) of the most recent. */
let recentLogs: MCP_ServerInstance.resourceHandler = async uri => {
  let q = queryOf(uri)
  let filter: LocalFeed.filter = {
    plugins: ?listOf(q, "plugins"),
    level: ?(q->Dict.get("level")->Option.flatMap(LocalFeed.levelOfString)),
    components: ?listOf(q, "components"),
    correlationId: ?(q->Dict.get("correlationId")),
  }
  let records = LocalLogFeed.recentRecords(~filter, ~limit=intOf(q, "limit")->Option.getOr(200))
  resourceResult(
    ~uri,
    Dict.fromArray([
      ("records", records->Array.map(Logger.recordToJson)->JSON.Encode.array),
    ])->JSON.Encode.object,
  )
}

/** `platform/events?…`: one page of the read across every log, newest first.
    Takes the filter of `Platform_EventLog` as query parameters (lists comma
    separated) and `first` and `after`. */
let events: MCP_ServerInstance.resourceHandler = async uri => {
  let q = queryOf(uri)
  let filter: LocalEventLogRead.filter = {
    plugins: ?listOf(q, "plugins"),
    logs: ?listOf(q, "logs"),
    eventTypes: ?listOf(q, "eventTypes"),
    entityId: ?(q->Dict.get("entityId")),
    tagKey: ?(q->Dict.get("tagKey")),
    tagValue: ?(q->Dict.get("tagValue")),
    msgId: ?(q->Dict.get("msgId")),
    correlationId: ?(q->Dict.get("correlationId")),
    causationId: ?(q->Dict.get("causationId")),
    user: ?(q->Dict.get("user")),
    timeFrom: ?(q->Dict.get("timeFrom")),
    timeTo: ?(q->Dict.get("timeTo")),
  }
  let page = await LocalEventLogRead.read(
    ~filter,
    ~first=?intOf(q, "first"),
    ~after=?q->Dict.get("after"),
  )
  resourceResult(~uri, pageJson(page))
}

/** `platform/metrics?plugins=a,b`: the metrics counted since the platform started. */
let metricsResource: MCP_ServerInstance.resourceHandler = async uri =>
  resourceResult(~uri, LocalMetrics.read(~plugins=?listOf(queryOf(uri), "plugins")))

/** Registers the resources on the platform MCP server. */
let registerMcp = (server: MCP_ServerInstance.t) => {
  server.registerResource(
    ~name=recentLogsUri,
    ~definition={
      uriTemplate: recentLogsUri,
      name: recentLogsUri,
      description: "The platform's recent log records, oldest first. Query parameters: plugins, level, components, correlationId (narrow), limit (default 200).",
      mimeType: "application/json",
    },
    ~handler=recentLogs,
  )
  server.registerResource(
    ~name=eventsUri,
    ~definition={
      uriTemplate: eventsUri,
      name: eventsUri,
      description: "Every event of every log, newest first, one page at a time. Query parameters: plugins, logs, eventTypes, entityId, tagKey, tagValue, msgId, correlationId, causationId, user, timeFrom, timeTo, first, after (the page's endCursor).",
      mimeType: "application/json",
    },
    ~handler=events,
  )
  server.registerResource(
    ~name=metricsUri,
    ~definition={
      uriTemplate: metricsUri,
      name: metricsUri,
      description: "The metrics counted since the platform started, per metric, plugin and slice: count, sum of values, last time, and counts of the last 60 minutes. Query parameter: plugins (narrow).",
      mimeType: "application/json",
    },
    ~handler=metricsResource,
  )
}
