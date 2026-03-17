# Pulumi State Management: Cloud Console vs Local/S3 Backend

## Goal

Evaluate whether reventless deployments can use Pulumi **without paying license fees**, by comparing the managed Pulumi Cloud backend against self-managed backends (local filesystem or AWS S3).

## Background

Pulumi stores infrastructure state (resource metadata, outputs, dependency graph) in a **backend**. By default this is Pulumi Cloud (`app.pulumi.com`), but the open-source CLI supports entirely self-managed backends with no license restrictions.

---

## Approach 1: Pulumi Cloud (Managed Backend)

### How it works

- `pulumi login` connects to Pulumi Cloud by default
- State is stored, encrypted, and managed by Pulumi's hosted service
- Web console at `app.pulumi.com` provides UI for stack history, drift detection, and team management

### Pricing (as of March 2026)

| Tier | Cost | Resources | Users |
|------|------|-----------|-------|
| **Individual** (Free) | $0 | Unlimited projects/stacks | 1 member, 1 org |
| **Team** | $40/mo + $0.18/resource above 500 | 500 included | Up to 10 |
| **Enterprise** | $400/mo + $0.37/resource above 2,000 | 2,000 included | Unlimited |
| **Business Critical** | Custom | Custom | Unlimited + self-hosting |

The free Individual tier is limited to **1 member and 1 organization** — unsuitable for any team workflow.

### Advantages

- **Zero operational burden** — Pulumi manages backups, availability, access control
- **Transactional checkpointing** — fault-tolerant state updates with automatic recovery
- **Built-in secrets management** — encryption keys managed by Pulumi
- **Web console** — visual stack history, resource explorer, audit logs
- **Concurrent state locking** — built-in with conflict resolution
- **RBAC and team policies** — granular access control (Team tier and above)
- **Drift detection** — automatic detection of out-of-band changes (Enterprise)
- **Deployment history** — full audit trail with rollback capability

### Consequences

- **License cost** — any team usage requires at minimum $40/month (Team tier), scaling with resource count
- **Vendor dependency** — state is hosted by Pulumi; migration requires export/import
- **Network requirement** — every `pulumi up` communicates with Pulumi Cloud API
- **Credential exposure risk** — Pulumi Cloud never receives cloud credentials (CLI talks to AWS directly), but access tokens for the Pulumi service itself must be managed
- **Resource-based pricing scales unpredictably** — at $0.18/resource, 100 resources = $18/mo extra; a multi-plugin deployment could add up quickly

---

## Approach 2: Self-Managed Backend (Local or S3)

### How it works

```bash
# Local filesystem
pulumi login --local          # state in ~/.pulumi
pulumi login file:///app/data # custom path

# AWS S3 (recommended for teams)
pulumi login s3://<bucket-name>
pulumi login 's3://<bucket-name>?region=eu-central-1&awssdk=v2&profile=dev'
```

State is stored as JSON files in the chosen backend. The Pulumi CLI operates entirely offline from Pulumi's servers.

### Pricing

| Component | Cost |
|-----------|------|
| Pulumi CLI | **$0** (open source, Apache 2.0) |
| S3 storage | ~$0.023/GB/month (negligible for state files) |
| S3 requests | ~$0.005/1,000 PUT requests (negligible) |
| KMS (if used for secrets) | $1/key/month + $0.03/10,000 requests |
| **Total** | **Effectively $0** |

### Backend options for secrets encryption

Self-managed backends still support encrypted secrets via multiple providers:

| Provider | Command |
|----------|---------|
| Passphrase | `pulumi stack init --secrets-provider passphrase` |
| AWS KMS | `pulumi stack init --secrets-provider awskms://alias/my-key` |
| Azure Key Vault | `pulumi stack init --secrets-provider azurekeyvault://...` |
| GCP KMS | `pulumi stack init --secrets-provider gcpkms://...` |
| HashiCorp Vault | `pulumi stack init --secrets-provider hashicorpvault://...` |

Using **AWS KMS** is the natural fit for reventless (already AWS-based) and provides enterprise-grade secret encryption at minimal cost.

### Advantages

- **Zero license cost** — no Pulumi subscription required, ever
- **No vendor dependency** — state lives in infrastructure you control
- **Offline operation** — no network calls to Pulumi servers
- **Full feature parity for core IaC** — `pulumi up`, `pulumi preview`, `pulumi destroy`, stack outputs, secrets, resource dependencies all work identically
- **State locking** — supported on S3 backends (uses lock files) since Pulumi v3.x
- **History tracking** — automatic checkpoint history per stack stored alongside state
- **Unlimited resources, users, stacks** — no tier limits
- **S3 versioning for safety** — enable S3 bucket versioning for point-in-time state recovery
- **CI/CD friendly** — `PULUMI_BACKEND_URL=s3://bucket` in environment, no login tokens needed

### Consequences

- **No web console** — no visual UI for stack inspection; must use CLI (`pulumi stack`, `pulumi stack history`, `pulumi stack export`)
- **No built-in RBAC** — access control is managed via S3 bucket policies and IAM; sufficient for small teams but less granular than Pulumi Cloud
- **No drift detection** — must be implemented manually (e.g., periodic `pulumi preview` in CI)
- **No audit logs** — rely on S3 access logging or CloudTrail instead
- **Manual backup responsibility** — mitigated by S3 cross-region replication or versioning
- **Concurrent access requires discipline** — S3 locking works but is less robust than Pulumi Cloud's transactional API; for single-developer or CI-serialized deployments this is a non-issue
- **Passphrase management** — if using passphrase-based secrets, the passphrase must be shared securely (use KMS instead)

---

## Head-to-Head Comparison

| Dimension | Pulumi Cloud | Self-Managed (S3) |
|-----------|-------------|-------------------|
| **License cost** | $40–400+/mo | $0 |
| **Infrastructure cost** | $0 | ~$1–2/mo (S3 + KMS) |
| **Setup effort** | Minimal (sign up) | Low (create S3 bucket + KMS key) |
| **State reliability** | Transactional API | S3 eventual consistency (adequate) |
| **Secrets encryption** | Built-in | AWS KMS (equivalent security) |
| **State locking** | Built-in | Built-in (S3 lock files) |
| **Web UI** | Yes | No |
| **Drift detection** | Enterprise tier ($400/mo) | Manual (`pulumi preview` in CI) |
| **RBAC** | Team tier ($40/mo) | IAM policies |
| **Audit trail** | Built-in | CloudTrail / S3 access logs |
| **Offline operation** | No | Yes |
| **CI/CD integration** | Access token required | S3 IAM role (simpler) |
| **Vendor lock-in** | Moderate | None |
| **Team scalability** | Tiered pricing | Unlimited |

---

## Recommendation

**Use the self-managed S3 backend.** It meets the goal of zero Pulumi license costs while providing all capabilities needed for reventless deployments:

### Recommended setup

```
s3://reventless-pulumi-state/
├── .pulumi/
│   ├── stacks/<project>/<stack>.json    # Current state
│   ├── history/<project>/<stack>/       # State history
│   └── locks/<project>/<stack>.json     # Operation locks
```

**S3 bucket configuration:**
- Versioning enabled (point-in-time recovery)
- Server-side encryption (SSE-S3 or SSE-KMS)
- Block all public access
- Lifecycle rule to expire old versions after 90 days

**Secrets provider:** AWS KMS with a dedicated key per environment (dev/staging/prod).

**CI/CD integration:**
```bash
export PULUMI_BACKEND_URL=s3://reventless-pulumi-state
export AWS_REGION=eu-central-1
pulumi stack select dev
pulumi up --yes
```

### What you give up (and why it's acceptable)

1. **Web console** — reventless is a small team; CLI output and CI logs provide sufficient visibility
2. **Drift detection** — add a scheduled `pulumi preview` job in CI to detect drift (free)
3. **RBAC** — IAM policies on the S3 bucket provide equivalent access control for the team size
4. **Transactional state API** — S3 locking is sufficient when deployments are serialized through CI (which they should be regardless)

### Migration path

If team size or compliance requirements grow, migrating from S3 to Pulumi Cloud is straightforward:
```bash
pulumi stack export --file state.json   # from S3 backend
pulumi login                             # switch to Pulumi Cloud
pulumi stack import --file state.json   # import into Cloud
```

This makes the S3 approach a **zero-risk starting point** — you can upgrade to Pulumi Cloud later without rework.

---

## Building a Custom Dashboard with Reventless

The main feature lost by choosing the S3 backend is the **web console**. This section evaluates building a lightweight replacement using the reventless framework itself — turning "no web console" from a trade-off into an advantage.

### Data already available

Reventless stack exports already contain rich, structured metadata about every deployed resource. Each plugin exports a `Resource.t` record per infrastructure component:

```rescript
type t = {
  name: string,    // Logical name (e.g. "OrdersAggrEventLog")
  id: string,      // AWS resource ID (e.g. DynamoDB table name)
  urn: string,     // Pulumi URN
  info: string,    // ARN or connection string
  service: string, // AWS service type: "DynamoDb", "SQS_FIFO", "Lambda", "S3", etc.
}
```

The `service` field uses a closed set of known AWS service types (`DynamoDb`, `DynamoDbStream`, `SQS`, `SQS_FIFO`, `SNS`, `SNS_FIFO`, `Lambda`, `S3`, `AppSync`, `IAM`, `CloudwatchEventRule`), which makes it straightforward to generate deep links into the AWS Console.

The plugin export structure (`Plugin.resolvedOutputs`) provides a complete inventory:

```json
{
  "id": "catalog-plugin",
  "version": "1.2.0",
  "readModels": {
    "CatalogItems": {
      "name": "CatalogItems",
      "queryDb": {
        "resources": [
          { "name": "CatalogItemsQueryDB", "id": "catalog-items-table", "urn": "...",
            "info": "arn:aws:dynamodb:eu-central-1:123:table/catalog-items-table",
            "service": "DynamoDb" }
        ]
      },
      "sourceNames": ["ItemCatalog"]
    }
  },
  "extensionPoints": {
    "CatalogSync": {
      "name": "CatalogSync",
      "commandTopic": { "resources": [...] },
      "eventTopic": { "resources": [...] }
    }
  }
}
```

### AWS Console deep-link mapping

Given the `service` and `info` (ARN) or `id` fields, deep links can be generated deterministically:

| Service | AWS Console URL pattern |
|---------|------------------------|
| `DynamoDb` | `https://{region}.console.aws.amazon.com/dynamodbv2/home?region={region}#table?name={id}` |
| `Lambda` | `https://{region}.console.aws.amazon.com/lambda/home?region={region}#/functions/{id}` |
| `SQS` / `SQS_FIFO` | `https://{region}.console.aws.amazon.com/sqs/v3/home?region={region}#/queues/{encodedArn}` |
| `SNS` / `SNS_FIFO` | `https://{region}.console.aws.amazon.com/sns/v3/home?region={region}#/topic/{arn}` |
| `S3` | `https://s3.console.aws.amazon.com/s3/buckets/{id}?region={region}` |
| `AppSync` | `https://{region}.console.aws.amazon.com/appsync/home?region={region}#/{id}/v1/home` |
| `CloudwatchEventRule` | `https://{region}.console.aws.amazon.com/events/home?region={region}#/eventbus/default/rules/{id}` |
| `IAM` | `https://console.aws.amazon.com/iam/home#/roles/{id}` |

The region is either extracted from the ARN (`arn:aws:service:REGION:account:...`) or configured globally for the dashboard.

### Dashboard architecture

The dashboard would be a **reventless plugin** itself — eating its own dog food:

```
reventless-dashboard (plugin)
├── Aggregate: DeploymentRegistry
│   ├── Commands: RegisterDeployment, UpdateDeployment
│   └── Events: DeploymentRegistered, DeploymentUpdated
├── ReadModel: PlatformOverview
│   └── Projection: platform → plugins → resources (hierarchical)
├── ReadModel: ResourceInventory
│   └── Projection: flat list of all resources across all plugins
└── API: Dashboard queries (GraphQL via AppSync)
```

**Data ingestion** — after each `pulumi up`, a post-deployment step reads the stack exports and emits a `RegisterDeployment` command:

```bash
# CI/CD post-deploy hook
pulumi stack output --json | curl -X POST https://dashboard-api/register \
  -H "Content-Type: application/json" \
  -d @-
```

Or directly from the Pulumi program itself, as a final step that calls the dashboard's command topic.

### What the dashboard would show

**Platform view:**
- List of all plugins deployed to this platform
- Per-plugin: version, deployment timestamp, stack name, environment (dev/staging/prod)
- Health indicator based on heartbeat status

**Plugin detail view:**
- Component tree: aggregates, read models, extension points, DCB event logs, tasks
- Per component: list of AWS resources with type badges (DynamoDB, Lambda, SQS, etc.)
- Each resource is a clickable link opening the AWS Console directly at that resource
- Stack outputs and configuration values

**Resource inventory view:**
- Flat, searchable/filterable table of all AWS resources across all plugins
- Filter by service type (show me all DynamoDB tables, all Lambda functions)
- Each row links to AWS Console

**Deployment history:**
- Timeline of deployments per plugin (from the aggregate's event stream)
- Diff view: which resources were added/removed/updated between deployments

### Implementation effort

| Component | Effort | Notes |
|-----------|--------|-------|
| **Aggregate + events** | Low | Standard reventless aggregate, ~2 commands and ~2 events |
| **Read models** | Low | Two projections over deployment events |
| **API** | Low | GraphQL queries already provided by reventless plugin infrastructure |
| **Frontend** | Medium | Static SPA (React or vanilla) calling the AppSync API; the main work is the UI itself |
| **Deep-link generation** | Low | Pure function: `(service, id, info, region) → URL` — deterministic mapping from the table above |
| **CI/CD integration** | Low | One `curl` or SDK call after `pulumi up` |
| **Total** | **~2–3 days** | For a functional MVP; polish and additional views can follow iteratively |

### Advantages over Pulumi Cloud console

- **Domain-aware** — understands reventless concepts (plugins, aggregates, read models) instead of showing a flat resource list
- **Hierarchical navigation** — platform → plugin → component → AWS resource, matching the mental model
- **Direct AWS Console links** — one click from any resource to its AWS Console page
- **Zero license cost** — runs on the same reventless infrastructure
- **Extensible** — add deployment diffs, cost estimates, or alerting as needed
- **Self-hosting** — no external service dependency; the dashboard is just another plugin
- **Event-sourced history** — full audit trail of all deployments as first-class events, queryable and replayable

### What it would not replace

- **Drift detection** — still requires periodic `pulumi preview` (the dashboard shows what _was_ deployed, not whether AWS has drifted)
- **State management** — the dashboard reads stack exports but does not replace the S3 state backend
- **Deployment execution** — `pulumi up` still runs from CI/CD; the dashboard is read-only
