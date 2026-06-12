/**
Minimal zod bindings — just enough to express the input shapes that
`@anthropic-ai/claude-agent-sdk`'s `tool()` helper expects (a ZodRawShape:
a dict of zod type values).
*/

type t

type zNamespace

@module("zod") external z: zNamespace = "z"

@send external string: (zNamespace, unit) => t = "string"

@send external describe: (t, string) => t = "describe"

/** `z.string().describe(description)` — the only shape the synthesis tools need. */
let describedString = (description: string): t => z->string()->describe(description)
