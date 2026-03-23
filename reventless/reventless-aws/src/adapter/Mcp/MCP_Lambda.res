// AWS MCP adapter — Lambda Function URL with Streamable HTTP transport.
//
// Deploy-time: creates a Lambda function bundled with @modelcontextprotocol/sdk
// and a Function URL for Streamable HTTP access.
//
// Runtime: the Lambda handler parses MCP protocol requests, routes tool calls
// to SQS CommandTopics and resource reads to DynamoDB QueryDbs — the same
// backend as AppSync resolvers. Event history resources read directly from
// EventLog and DcbEventLog DynamoDB tables.
//
// NOTE: Lambda Function URL bindings for rescript-pulumi-aws are not yet
// available. This module provides the runtime MCP server handler that will
// be deployed once the Pulumi bindings are added. The deploy-time infrastructure
// (Lambda + Function URL + IAM role) is documented but not yet wired to Pulumi.

// ─── Runtime handler ───────────────────────────────────────────────────────

type mcpToolEntry = {
  name: string,
  description: string,
  inputSchema: JSON.t,
  commandTopicArn: string,
}

type mcpResourceEntry = {
  name: string,
  description: string,
  uriTemplate: string,
  queryDbTableName: string,
}

type mcpEventHistoryEntry = {
  name: string,
  displayName: string,
  tableName: string,
  busKey: string,
}

type mcpConfig = {
  serverName: string,
  serverVersion: string,
  tools: array<mcpToolEntry>,
  resources: array<mcpResourceEntry>,
  eventHistoryResources: array<mcpEventHistoryEntry>,
}

/** Generate the MCP config from plugin schema entries.
    Called at deploy time to produce the config JSON that the Lambda reads
    from its environment variable. */
let generateConfig = (
  ~serverName: string,
  ~serverVersion: string,
  ~pluginName: string,
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  ~eventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>=[],
  ~commandTopicArns: dict<string>,
  ~queryDbTableNames: dict<string>,
  ~eventLogTableNames: dict<string>=Dict.make(),
): mcpConfig => {
  let toolDefs = ReventlessCore.MCP_SchemaGenerator.generateTools(~pluginName, ~mutationEntries)
  let tools = toolDefs->Array.map(def => {
    name: def.name,
    description: def.description,
    inputSchema: def.inputSchema,
    commandTopicArn: commandTopicArns->Dict.get(def.name)->Option.getOr(""),
  })

  let resourceDefs = ReventlessCore.MCP_SchemaGenerator.generateResources(
    ~pluginName,
    ~queryEntries,
  )
  let resources = resourceDefs->Array.map(def => {
    name: def.name,
    description: def.description,
    uriTemplate: def.uriTemplate,
    queryDbTableName: queryDbTableNames->Dict.get(def.name)->Option.getOr(""),
  })

  let eventHistoryResources = eventLogEntries->Array.map(entry => {
    let nameLower = entry.displayName->String.toLowerCase
    {
      name: `${nameLower}_events`,
      displayName: entry.displayName,
      tableName: eventLogTableNames->Dict.get(entry.busKey)->Option.getOr(""),
      busKey: entry.busKey,
    }
  })

  {serverName, serverVersion, tools, resources, eventHistoryResources}
}

/** Generate the core-only MCP config for split mode.
    Contains only core administrative tools (Plugin_Activate, Plugin_Deactivate, Clone)
    and core resources (Plugin, Plugins). No plugin-contributed entries.

    The commandTopicArns and queryDbTableNames must map core field names to their
    corresponding AWS resource ARNs/names. When Lambda Function URL deployment is
    available (Step 13), these will be wired from Pulumi stack outputs. */
let generateAdminConfig = (
  ~serverName: string,
  ~serverVersion: string,
  ~cloner: bool=false,
  ~commandTopicArns: dict<string>=Dict.make(),
  ~queryDbTableNames: dict<string>=Dict.make(),
): mcpConfig =>
  generateConfig(
    ~serverName=`${serverName}-admin`,
    ~serverVersion,
    ~pluginName="Admin",
    ~mutationEntries=ReventlessCore.AdminApi.mutationEntries(~cloner),
    ~queryEntries=ReventlessCore.PluginBaseFragment.queryEntries,
    ~commandTopicArns,
    ~queryDbTableNames,
  )

// ─── URI parsing helpers ─────────────────────────────────────────────────

/** Extract entity ID from the last path segment (before any query string). */
let extractEntityId = (uri: string) => {
  let pathPart = (uri->String.split("?"))->Array.getUnsafe(0)
  let segments = pathPart->String.split("/")
  segments->Array.at(-1)->Option.getOr("")
}

/** Parse limit and after pagination params from a URI query string. */
let parsePaginationParams = (uri: string) => {
  let parts = uri->String.split("?")
  switch parts->Array.get(1) {
  | None => (None, None)
  | Some(qs) =>
    let params = Dict.make()
    qs->String.split("&")->Array.forEach(param => {
      let kv = param->String.split("=")
      switch (kv->Array.get(0), kv->Array.get(1)) {
      | (Some(k), Some(v)) => params->Dict.set(k, v)
      | _ => ()
      }
    })
    (
      params->Dict.get("limit")->Option.flatMap(v => Int.fromString(v)),
      params->Dict.get("after"),
    )
  }
}

/** Build a paginated response JSON with events and pagination metadata. */
let paginatedResponse = (
  ~events: array<JSON.t>,
  ~hasMore: bool,
  ~nextAfter: option<string>,
) =>
  Dict.fromArray([
    ("events", events->JSON.Encode.array),
    (
      "pagination",
      Dict.fromArray([
        ("hasMore", hasMore->JSON.Encode.bool),
        ("nextAfter", nextAfter->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
      ])->JSON.Encode.object,
    ),
  ])->JSON.Encode.object

// ─── Runtime event history handlers ──────────────────────────────────────

/** Read event history from an EventLog DynamoDB table (aggregate events).
    Uses the existing queryStream infrastructure for lazy DynamoDB pagination
    with Stream.take for efficient limiting. */
let readEventLogHistory = async (
  ~tableName: string,
  ~entityId: string,
  ~limit: option<int>=?,
  ~after: option<string>=?,
) => {
  let table: Util_DynamoDb_Runtime.resolvedTable = {
    id: "",
    name: tableName,
    arn: "",
    hashKey: "id",
  }

  let expressionAttributeValues = [(":id", entityId->JSON.Encode.string)]->Dict.fromArray

  let exclusiveStartKey = after->Option.map(afterSeq =>
    Dict.fromArray([
      ("id", entityId->JSON.Encode.string),
      ("seq", afterSeq->JSON.Encode.string),
    ])
  )

  let stream =
    Util_DynamoDb_Runtime.queryStream({
      tableName: table.name,
      consistentRead: true,
      keyConditionExpression: "id=:id",
      expressionAttributeValues,
      ?exclusiveStartKey,
    })
    ->Stream.catchAll(err => {
      let _ = DynamoDb_Error.message(err)
      Stream.empty
    })

  // Fetch limit+1 items to detect hasMore
  let bounded = switch limit {
  | Some(n) => stream->Stream.take(n + 1)
  | None => stream
  }

  let events = await bounded->Stream.runCollect->Effect.runPromise

  let (limited, hasMore) = switch limit {
  | Some(n) when events->Array.length > n =>
    (events->Array.slice(~start=0, ~end=n), true)
  | _ => (events, false)
  }

  let nextAfter = if hasMore {
    limited
    ->Array.at(-1)
    ->Option.flatMap(JSON.Decode.object)
    ->Option.flatMap(obj => obj->Dict.get("seq"))
    ->Option.flatMap(JSON.Decode.string)
  } else {
    None
  }

  paginatedResponse(~events=limited, ~hasMore, ~nextAfter)
}

/** Read event history from a DcbEventLog DynamoDB table.
    Uses the existing DcbEventLog runtime read with tag-based filtering. */
let readDcbEventLogHistory = async (
  ~tableName: string,
  ~entityId: string,
  ~limit: option<int>=?,
  ~after: option<string>=?,
) => {
  let table: Util_DynamoDb_Runtime.resolvedTable = {
    id: "",
    name: tableName,
    arn: "",
    hashKey: "id",
  }

  let result = await DcbEventLogStorage_DynamoDb_Runtime.read(table)(~query=[], ~after?)

  // Filter by entity ID tag value (events matching this entity)
  let filtered = if entityId->String.length > 0 {
    result.events->Array.filter(e => e.tags->Array.some(tag => tag.value == entityId))
  } else {
    result.events
  }

  // Apply limit
  let (limited, hasMore) = switch limit {
  | Some(n) when filtered->Array.length > n =>
    (filtered->Array.slice(~start=0, ~end=n), true)
  | _ => (filtered, false)
  }

  // Serialize events to JSON
  let eventsJson = limited->Array.map(e =>
    Dict.fromArray([
      ("position", JSON.Encode.string(e.position)),
      ("event", JSON.Encode.string(e.eventType)),
      ("data", e.data),
      (
        "tags",
        e.tags
        ->Array.map(t =>
          Dict.fromArray([
            ("key", JSON.Encode.string(t.key)),
            ("value", JSON.Encode.string(t.value)),
          ])->JSON.Encode.object
        )
        ->JSON.Encode.array,
      ),
    ])->JSON.Encode.object
  )

  let nextAfter = if hasMore {
    limited->Array.at(-1)->Option.map(e => e.position)
  } else {
    None
  }

  paginatedResponse(~events=eventsJson, ~hasMore, ~nextAfter)
}

// ─── Deploy-time infrastructure (placeholder) ─────────────────────────────
//
// When rescript-pulumi-aws gains Lambda Function URL bindings, this section
// will create:
//
//   1. Lambda function (Node.js 20.x runtime)
//      - Handler: mcp-handler.handler
//      - Environment: MCP_CONFIG = JSON.stringify(config)
//      - Bundled dependencies: @modelcontextprotocol/sdk, zod
//
//   2. Lambda Function URL
//      - Auth type: AWS_IAM (for Cognito/IAM auth) or NONE (for public access)
//      - CORS: configurable origin whitelist
//      - Invoke mode: RESPONSE_STREAM (for SSE support)
//
//   3. IAM Role
//      - sqs:SendMessage on all registered CommandTopic queues
//      - dynamodb:GetItem, dynamodb:Query on all registered QueryDb tables
//      - dynamodb:Query on all registered EventLog tables (event history)
//      - dynamodb:Query on all registered DcbEventLog tables + GSIs (event history)
//
// The Lambda handler code would:
//   - Read MCP_CONFIG from environment
//   - Create an MCP Server instance with registered tools and resources
//   - Tool handlers: SQS.sendMessage to the command topic ARN
//   - Resource handlers: DynamoDB.getItem/query on the table
//   - Event history handlers: readEventLogHistory / readDcbEventLogHistory
//   - Use StreamableHTTPServerTransport with the Lambda response stream

// ─── Auth and rate limiting configuration ────────────────────────────────
//
// MCP 1.0 standardizes on OAuth 2.0. The Lambda Function URL validates JWT
// tokens from the Authorization header using the same Cognito User Pool as
// AppSync.

/** Authentication mode for the Lambda Function URL. */
type authType =
  | /** AWS IAM auth — callers sign requests with SigV4. Suitable for
        service-to-service or Cognito identity pool access. */
  AwsIam
  | /** No auth — the Function URL is publicly accessible. Suitable for
        development or when auth is handled at a different layer (API Gateway). */
  None

/** Per-tool authorization scope. Tools can require specific Cognito groups
    or OAuth scopes before execution. */
type toolScope = {
  /** Tool name (must match a registered tool). */
  toolName: string,
  /** Required Cognito groups — the caller must belong to at least one. */
  requiredGroups?: array<string>,
  /** Required OAuth scopes — the caller's token must include at least one. */
  requiredScopes?: array<string>,
}

/** Rate limiting configuration (coarse, via Lambda reserved concurrency). */
type rateLimitConfig = {
  /** Maximum concurrent Lambda executions for the MCP endpoint. */
  reservedConcurrency?: int,
}

/** Full MCP deployment configuration for AWS. */
type deployConfig = {
  /** Authentication mode for the Function URL. */
  authType: authType,
  /** CORS allowed origins (e.g., ["https://app.example.com"]). */
  corsOrigins?: array<string>,
  /** Per-tool authorization scopes. */
  toolScopes?: array<toolScope>,
  /** Rate limiting configuration. */
  rateLimit?: rateLimitConfig,
  /** When true, only Resources are registered — no Tools. Useful for
      conservative initial rollout. */
  readOnly?: bool,
}

// Placeholder type for the deploy-time component output.
type outputs = {
  functionUrl: Pulumi.Output.t<string>,
  lambdaArn: Pulumi.Output.t<string>,
}
