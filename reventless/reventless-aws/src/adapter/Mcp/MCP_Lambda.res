// AWS MCP adapter — Lambda Function URL with Streamable HTTP transport.
//
// Deploy-time: creates a Lambda function bundled with @modelcontextprotocol/sdk
// and a Function URL for Streamable HTTP access.
//
// Runtime: the Lambda handler parses MCP protocol requests, routes tool calls
// to SQS CommandTopics and resource reads to DynamoDB QueryDbs — the same
// backend as AppSync resolvers.
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

type mcpConfig = {
  serverName: string,
  serverVersion: string,
  tools: array<mcpToolEntry>,
  resources: array<mcpResourceEntry>,
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
  ~commandTopicArns: dict<string>,
  ~queryDbTableNames: dict<string>,
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

  {serverName, serverVersion, tools, resources}
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
//
// The Lambda handler code would:
//   - Read MCP_CONFIG from environment
//   - Create an MCP Server instance with registered tools and resources
//   - Tool handlers: SQS.sendMessage to the command topic ARN
//   - Resource handlers: DynamoDB.getItem/query on the table
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
