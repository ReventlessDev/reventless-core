# AWS: wire Platform_Plugin_Activate / Platform_Plugin_Deactivate resolvers

## Problem

On AWS, the admin GraphQL mutations `Platform_Plugin_Activate` and
`Platform_Plugin_Deactivate` are declared in the AppSync SDL (via
`PluginBaseFragment.mutationEntries`) and Cognito-group-gated to `Admin`,
but **no resolvers are wired** — every invocation returns a GraphQL error.

The in-memory adapter cheats: its inline resolver updates the Plugin QueryDb
directly (see `reventless-in-memory/src/Platform.res:1372-1377`). On AWS we
want the proper event-sourced path: publish a command to the Plugin
aggregate's CommandTopic SQS queue, let `PluginBehavior` produce
`Activated` / `Deactivated` events, let `PluginProjection` update the read
model.

This plan was extracted from a conversation that already shipped:

1. `reventless-core/src/admin/Platform_Admin_Structure.res` — synthetic
   pluginStructure so the admin plugin appears in `Platform_UIDefinitions`.
2. `reventless-in-memory/src/Platform.res` — seeds the admin structure.
3. `reventless-in-memory/src/adapter/Auth/Auth_InMemory.res` — `defaultUser`
   includes the `Admin` group.
4. `reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res` —
   injects the admin entry into the AWS UIDefinitions response.

After those changes the admin plugin renders on AWS with its Plugin list
page (read model + queries already wired) and PlatformEventGraph view, but
the per-row Activate/Deactivate buttons error. This plan closes the gap.

## Constraint: Plugin aggregate is `Aggregate_Builder_NoResolver`

`reventless-aws/src/Platform.res:882-888` instantiates the Plugin aggregate
via `Aggregate_Builder_NoResolver` because user plugins drive Connect /
Heartbeat / Disconnect via `PluginConnectExtension.publishToAggregates` —
not via AppSync mutations. We don't want to flip it to `Aggregate_Builder`:
that would auto-expose Heartbeat / Connect / Disconnect /
ReportIncompatibility in the GraphQL schema, which is wrong.

So we need a **dedicated resolver Lambda** that handles only
Activate/Deactivate and publishes to the Plugin aggregate's existing
CommandTopic SQS queue.

## Design

### New file: `reventless-aws/src/adapter/Api/Platform_PluginCommand_Lambda.res`

Mirrors `Platform_UIDefinitions_Lambda.res` structurally (single Lambda +
IAM role + IAM policy + AppSync DataSource + N resolvers).

**Signature:**

```rescript
let make = (
  ~api: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  ~pluginCommandTopicResources: Pulumi.Output.t<array<ReventlessInfra.Adapter.resource>>,
  ~opts: Pulumi.ComponentResource.options,
) => unit
```

**Resource extraction** — the Plugin aggregate's CommandTopic provisions
one SQS FIFO queue. Get it by filtering `resources` for resourceType
`"aws:sqs:Queue"` (the value `Util_SQS.toResource` stamps onto SQS
resources at `reventless-aws/src/util/Util_SQS.res:14-20`). For an SQS
queue resource:

- `resource.id` → queue URL (used by Lambda env var + SendMessage)
- `resource.arn` → queue ARN (used by IAM `sqs:SendMessage` policy)

Pattern reference: `CommandGeneratorResolvers_AppSync.res:32-58` does this
filter via `ReventlessCore.Util.Adapter.filterSupportedResolvedResources([
AWS.SQS.service, AWS.SQS_FIFO.service])` after
`resourcesToResolvedOutput`.

### Lambda handler JS

The handler receives the AppSync payload shape produced by
`PulumiAws.AppSync.Resolver.Functions.invokeCommandGenerator(command)`
(see `rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res:794-829`):

```js
{
  command: "Activate" | "Deactivate",   // hardcoded per-resolver
  arguments: { id: "<aggregate-id>" },
  meta: { ip, user, info },
  identity: { ... }
}
```

It publishes a fully-formed Reventless command envelope to the Plugin
aggregate's SQS FIFO queue. Wire format from
`reventless-core/src/Message.res:53-63`:

```json
{
  "id": "<aggregate-id>",
  "meta": {
    "service": "platform-admin",
    "time": "<ISO-8601>",
    "msgId": "<UUID v4>",
    "correlationId": "<UUID v4>",
    "ip": "<optional>",
    "user": "<optional>"
  },
  "command": "Activate"
}
```

**Important:** payload-less ReScript variants (`Activate` / `Deactivate`)
serialize as **bare JSON strings**, not objects (confirmed at
`reventless-core/src/Message.res:89-98` `variantNameOfJson`). So
`"command": "Activate"` — no `TAG` wrapper.

**FIFO requirements** (per `Util_SQS_Runtime.res:23-28` / `:60-69`):

- `MessageGroupId` = `safeGroupId(id)` — `id` truncated to 128 chars, or
  SHA-256 hex if longer.
- `MessageDeduplicationId` = `meta.msgId` (the freshly-minted UUID).

Lambda code skeleton:

```js
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { randomUUID, createHash } from "crypto";

const sqs = new SQSClient({});
const QUEUE_URL = process.env.PLUGIN_AGGREGATE_QUEUE_URL;
const safeGroupId = (id) =>
  id.length <= 128 ? id : createHash("sha256").update(id).digest("hex");

export async function handler(event) {
  if (!QUEUE_URL) return { ok: false, error: "Configuration error" };
  const cmd = event.command;
  if (cmd !== "Activate" && cmd !== "Deactivate") {
    return { ok: false, error: "Unsupported command: " + cmd };
  }
  const id = event.arguments && event.arguments.id;
  if (!id) return { ok: false, error: "Missing aggregate id" };

  const msgId = randomUUID();
  const meta = {
    service: "platform-admin",
    time: new Date().toISOString(),
    msgId,
    correlationId: randomUUID(),
    ip: event.meta?.ip ?? null,
    user: event.meta?.user ?? null,
  };
  const body = JSON.stringify({ id, meta, command: cmd });

  await sqs.send(new SendMessageCommand({
    QueueUrl: QUEUE_URL,
    MessageBody: body,
    MessageGroupId: safeGroupId(id),
    MessageDeduplicationId: msgId,
  }));
  return { ok: true, msgId };
}
```

### AppSync resolver wiring

Reuse the existing `invokeCommandGenerator(commandName)` resolver code from
`rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res:794-829`.
Two resolvers — one per mutation field — each passing its own command
string:

```rescript
let activateField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Activate")
let deactivateField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Deactivate")

["Activate", "Deactivate"]->Array.forEach(command => {
  let field = ReventlessCore.Api_Naming.adminField(~name="Plugin_" ++ command)
  let _ = AppSync_Resolver_Native.makeUnitJsResolver(
    ~name=name ++ command ++ "Resolver",
    ~api,
    ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
    ~type_="Mutation"->Pulumi.Input.make,
    ~field=field->Pulumi.Input.make,
    ~code=PulumiAws.AppSync.Resolver.Functions.invokeCommandGenerator(command)
      ->Pulumi.Input.make,
    ~opts,
  )
})
```

### IAM

Lambda role needs:

1. `logs:*` on `arn:aws:logs:*:*:*` (standard).
2. `sqs:SendMessage` on the Plugin aggregate's queue ARN only.

DataSource role needs:

1. `lambda:InvokeFunction` on the new Lambda's ARN.

Both follow the exact pattern in
`Platform_UIDefinitions_Lambda.res:65-100`.

### Wiring in `reventless-aws/src/Platform.res`

Admin.construct returns `admin.aggregatesOutputs: dict<Aggregate.outputs>`
keyed by `Spec.name` — confirmed by `Builder_Helpers.res:28-44`. For the
Plugin aggregate the key is **`"Plugin"`** (from `PluginSpec.res` `name`).

`Aggregate.outputs.commandTopic` is `Pulumi.Output.t<CommandTopic.outputs>`,
where `CommandTopic.outputs = {resources: array<Adapter.resource>}`. Path:

```rescript
let pluginCommandTopicResources =
  admin.aggregatesOutputs
  ->Dict.get("Plugin")
  ->Option.map(out => out.commandTopic->Pulumi.Output.map(ct => ct.resources))
```

Wire `Platform_PluginCommand_Lambda.make` at both Admin construction sites
in `Platform.res`:

1. **Split mode** — around line 1020 (right after
   `Platform_UIDefinitions_Lambda.make` for the platform API).
2. **Unified mode** — the equivalent section around line 1255-1259.

Mount on `platformApi` (which equals `domainApi` in unified mode).

## Auth

The admin mutations are already injected with
`@aws_auth(cognito_groups: ["Admin"])` via
`AppSync_Adapter.injectAwsAuthAll` at `Platform.res:1062-1064`
(split) / `1287-1288` (unified). AppSync enforces group membership before
the resolver runs — no extra auth code needed in the Lambda.

## Verification checklist

1. `pnpm exec rescript build` clean — zero warnings.
2. Deploy to alpha stack with at least one user plugin connected.
3. Log in as a Cognito user in the `Admin` group.
4. In the host shell, open the Platform plugin's Plugin list page.
5. Click **Deactivate** on a Connected plugin. Expected:
   - GraphQL mutation returns `{msgId: "..."}`.
   - SQS message visible in CloudWatch / SQS console on the Plugin queue.
   - Plugin aggregate's existing handler logs `PluginDeactivated`.
   - Plugin read model row updates `status` from `Connected` → `Inactive`.
   - Host shell row re-renders.
6. Click **Activate** on an Inactive plugin. Expected: same flow,
   `status` → `Disconnected` (per `PluginBehavior`).
7. Negative test: log in as a non-Admin user. Mutations rejected by
   AppSync with an `Unauthorized` error.

## Out of scope

- `Heartbeat` / `Connect` / `Disconnect` / `ReportIncompatibility` —
  these stay internal to the ExtensionPoint flow.
- Refactoring the Plugin aggregate to `Aggregate_Builder` — explicitly
  avoided (would auto-expose all commands).
- Touching `MCP_Lambda.res` — its existing references to Plugin_Activate /
  Plugin_Deactivate (line 106) are MCP tool descriptions, not resolver
  wiring.

## References

- `reventless-core/src/admin/PluginSpec.res` — command/event types.
- `reventless-core/src/admin/PluginBehavior.res` — decision logic.
- `reventless-core/src/admin/PluginBaseFragment.res:39-50` — SDL field
  declarations.
- `reventless-core/src/admin/Platform_Admin_Structure.res` — synthetic
  pluginStructure (already shipped).
- `reventless-aws/src/Platform.res:882-888` — Plugin aggregate
  instantiation site.
- `reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res` —
  structural template for the new Lambda module.
- `reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res:32-58` —
  SQS resource filtering pattern.
- `reventless-aws/src/util/Util_SQS_Runtime.res:23-28, 60-69` —
  `safeGroupId` + FIFO send semantics.
- `rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res:794-829` —
  `invokeCommandGenerator` resolver code template.
- `reventless-core/src/Message.res:53-63, 89-98` — command envelope wire
  format + payload-less variant encoding.
- `reventless-in-memory/src/Platform.res:1372-1377` — in-memory shortcut
  (intentionally bypasses aggregate; not the model for AWS).
