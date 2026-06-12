/**
Bindings for `@anthropic-ai/sdk` — the surface the Reventless behavior
synthesis loop needs: client construction, the Messages API (plain and beta)
with adaptive thinking / effort / task budgets, tool definitions, content
blocks, and usage accounting.

Response unions (content blocks) are modeled as records with optional fields
discriminated by `type_` — read the fields that the `type_` value implies.
*/

type client

type clientOptions = {apiKey?: string, authToken?: string, maxRetries?: int}

/** `new Anthropic()` — credentials resolved from the environment
    (ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / an `ant auth login` profile). */
@new @module("@anthropic-ai/sdk")
external make: unit => client = "default"

@new @module("@anthropic-ai/sdk")
external makeWithOptions: clientOptions => client = "default"

// ---------------------------------------------------------------------------
// Request parameters
// ---------------------------------------------------------------------------

type cacheControl = {@as("type") type_: string}

/** `{type: "ephemeral"}` — the default 5-minute-TTL cache breakpoint. */
let ephemeral: cacheControl = {type_: "ephemeral"}

type textBlockParam = {
  @as("type") type_: string,
  text: string,
  cache_control?: cacheControl,
}

let textBlock = (~cacheControl: option<cacheControl>=?, text: string): textBlockParam => {
  type_: "text",
  text,
  cache_control: ?cacheControl,
}

/** `thinking: {type: "adaptive"}` — the only on-mode for Opus 4.7+. */
type thinkingConfig = {@as("type") type_: string}

let adaptiveThinking: thinkingConfig = {type_: "adaptive"}

type taskBudget = {@as("type") type_: string, total: int}

let tokenTaskBudget = (total: int): taskBudget => {type_: "tokens", total: total}

type outputConfig = {
  effort?: string,
  task_budget?: taskBudget,
}

type toolDefinition = {
  name: string,
  description: string,
  input_schema: JSON.t,
}

// ---------------------------------------------------------------------------
// Messages and content
// ---------------------------------------------------------------------------

/** Message content is a union (string | content-block array); constructors
    below cover the shapes the API accepts. */
type messageContent

external contentFromText: string => messageContent = "%identity"
external contentFromParams: array<textBlockParam> => messageContent = "%identity"

type toolResultBlockParam = {
  @as("type") type_: string,
  tool_use_id: string,
  content: string,
  is_error?: bool,
}

external contentFromToolResults: array<toolResultBlockParam> => messageContent = "%identity"

type message = {role: string, content: messageContent}

// ---------------------------------------------------------------------------
// Response
// ---------------------------------------------------------------------------

type usage = {
  input_tokens?: float,
  output_tokens?: float,
  cache_read_input_tokens?: Nullable.t<float>,
  cache_creation_input_tokens?: Nullable.t<float>,
}

/** Discriminated by `type_`: "text" (→ `text`), "tool_use" (→ `id`, `name`,
    `input`), "thinking" (→ `thinking`). */
type contentBlock = {
  @as("type") type_: string,
  id?: string,
  name?: string,
  input?: JSON.t,
  text?: string,
  thinking?: string,
}

/** Echo a response's content back as an assistant turn (preserves tool_use
    and thinking blocks, as the API requires). */
external contentFromResponseBlocks: array<contentBlock> => messageContent = "%identity"

type response = {
  content: array<contentBlock>,
  stop_reason?: Nullable.t<string>,
  usage?: usage,
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

type request = {
  model: string,
  max_tokens: int,
  thinking?: thinkingConfig,
  output_config?: outputConfig,
  system?: array<textBlockParam>,
  tools?: array<toolDefinition>,
  messages: array<message>,
  /** Beta namespace only (`client.beta.messages.create`). */
  betas?: array<string>,
}

type messagesNamespace

@get external messages: client => messagesNamespace = "messages"

type betaNamespace

@get external beta: client => betaNamespace = "beta"
@get external betaMessages: betaNamespace => messagesNamespace = "messages"

@send external create: (messagesNamespace, request) => promise<response> = "create"
