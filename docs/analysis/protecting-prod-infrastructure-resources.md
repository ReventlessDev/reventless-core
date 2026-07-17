# Protecting Production Infrastructure Resources

## Context

Reventless deploys all AWS infrastructure through Pulumi. The most catastrophic
operator mistakes are:

- `pulumi destroy` on the wrong stack (typo, wrong terminal, automation glitch)
- `aws dynamodb delete-table` on the wrong table
- A Pulumi diff that **replaces** a table because of a schema change to an
  immutable attribute (e.g. `hashKey`, `rangeKey`, GSI key schema) — Pulumi
  silently delete-then-creates the resource and the entire event log is gone
- A force-deploy from a branch that drops a resource the operator did not
  realize was load-bearing

For the framework, the highest-value resources to protect are the **EventLog**
and **DcbEventLog** tables (`Util_DynamoDbStream.makeTable` in
`reventless/aws/src/adapter/EventLog/` and
`adapter/DcbEventLog/`) — they are the system of record. Losing a QueryDb
projection is recoverable (replay); losing the event log is not.

The existing
[`clearing-aws-eventlog-querydb-tables.md`](./clearing-aws-eventlog-querydb-tables.md)
document describes the **intentional** wipe path. This document is the
counterpart: how to make sure the wipe never happens by accident on prod.

## Layered Defence

Four independent layers, in order of strength. Each layer should be enabled on
prod; non-prod stacks can opt out per layer as appropriate.

1. **DynamoDB-native deletion protection** — last line of defence, lives in
   AWS itself, survives even a `pulumi destroy --yes`.
2. **Pulumi resource `protect: true`** — Pulumi refuses to delete or replace
   the resource until the flag is explicitly cleared.
3. **Pulumi `retainOnDelete: true`** — Pulumi forgets about the resource on
   delete but does not actually delete it in AWS.
4. **IAM / SCP guardrails** — deny `dynamodb:DeleteTable` and friends for
   prod tables outside a break-glass role.

Backups (PITR, on-demand) are not a protection layer — they are a recovery
layer. Treat them as orthogonal and always-on (PITR is already enabled by
`Util_DynamoDb.makeTableArgs`).

---

### Layer 1 — DynamoDB `deletion_protection_enabled`

The strongest protection because it lives at the AWS API. Once enabled,
`DeleteTable` returns `ResourceInUseException` regardless of which IAM
principal or Pulumi command issued it. Disabling it requires a separate
`UpdateTable` call with `DeletionProtectionEnabled=false`.

Pulumi exposes this on `aws.dynamodb.Table` as `deletionProtectionEnabled`.

**Recommended change**: thread a flag through `Util_DynamoDb.makeTableArgs`
that defaults to `true` when `Pulumi.Pulumi.getStackName()` matches a prod
pattern (e.g. `prod`, `production`, `main`). Pseudocode for the change in
`reventless/aws/src/util/Util_DynamoDb.res`:

```rescript
let isProdStack = () => {
  let stack = Pulumi.Pulumi.getStackName()
  stack == "prod" || stack == "production" || stack == "main"
}

let makeTableArgs = (
  ~attributes,
  ...,
  ~deletionProtectionEnabled=?,
) => {
  {
    ...,
    deletionProtectionEnabled: (deletionProtectionEnabled->Option.getOr(isProdStack()))
      ->Pulumi.Input.make,
  }
}
```

This protects every table the framework creates (EventLog, DcbEventLog, every
QueryDb) on prod stacks, with a zero-config default and an explicit override
escape hatch.

**Side effects to be aware of**:

- `pulumi destroy` of the stack will fail mid-way on the protected tables.
  This is the desired outcome — the operator must consciously unprotect
  before destruction.
- Schema-change replacements (immutable attribute edits) will also fail.
  Again desired — those changes deserve a manual review on prod.

### Layer 2 — Pulumi `protect: true`

Pulumi's `protect` flag is checked **before** the AWS API call is made. It
catches the mistake earlier in the workflow (the operator sees a clear error
during `pulumi preview`, not after the API call already deleted something).

It is set in `Pulumi.ComponentResource.options` / `CustomResourceOptions`. The
opts record is already threaded through every component builder, so adding
`protect` is a one-line change in `Util_DynamoDb.makeTable` and
`Util_DynamoDbStream.makeTable`:

```rescript
~opts={
  ...opts,
  protect: isProdStack(),
  dependsOn: dependencies->Pulumi.Output.asInput,
},
```

To temporarily disable protection (e.g. for an intentional schema migration),
the operator runs:

```bash
pulumi state unprotect <urn>
pulumi up           # perform the change
# Re-apply protection by re-running pulumi up; the code re-asserts protect: true
```

The unprotect step is two-factor — it requires an explicit second command
plus URN — which is exactly the friction we want.

### Layer 3 — `retainOnDelete: true`

A weaker but complementary flag. Where `protect` blocks `pulumi destroy`,
`retainOnDelete` allows Pulumi to forget the resource but leaves the
underlying AWS resource in place. The table still exists in DynamoDB and can
be re-imported.

Useful for **read-side projections** (QueryDb) where you might want to
decommission a read model in code without losing the data immediately —
operators can later inspect or delete the table manually after confirming
the projection is no longer needed.

For **EventLog/DcbEventLog**, `protect: true` is the right answer, not
`retainOnDelete` — you do not want operators to ever "decommission" the event
log via a code change.

### Layer 4 — IAM / SCP guardrails

The above three layers can all be bypassed by a user with sufficient AWS
credentials. The final layer is an IAM policy or AWS Organizations SCP that
denies `dynamodb:DeleteTable`, `dynamodb:UpdateTable` (with
`DeletionProtectionEnabled=false`), and `dynamodb:DisableKinesisStreamingDestination`
on prod-suffixed table ARNs, except for an explicit break-glass role.

Pulumi runs under an IAM role; that role must be allowed to **create** and
**update** tables but **denied** delete on prod. A separate
`break-glass-prod-dba` role exists for the rare intentional wipe and is
assumed only via MFA + ticketed approval.

This layer lives outside the Reventless code itself (org-level / account-level
IAM), but the framework can publish a recommended policy template alongside
the deployment guide.

---

## Pulumi-Specific Footguns to Avoid

### Immutable attribute changes silently destroy data

DynamoDB does not allow changing `hashKey`, `rangeKey`, or GSI key schema
in place — Pulumi will plan a **replacement**, which means delete-then-create.
Without `protect` or `deletionProtectionEnabled`, this happens during a
normal `pulumi up` with no special warning beyond the standard diff output.

`protect: true` and `deletionProtectionEnabled: true` both block this. With
either layer enabled, the operator gets an explicit error and must
consciously choose the migration path (see
`clearing-aws-eventlog-querydb-tables.md`).

### `pulumi refresh` after manual deletion

If someone deletes a table manually (`aws dynamodb delete-table`) and then
runs `pulumi refresh`, Pulumi reconciles state and silently records the
table as gone. The next `pulumi up` recreates an **empty** table with the
same name, which masks the data loss until someone notices missing events.

PITR (already enabled by default in `Util_DynamoDb.makeTableArgs`) is the
recovery mechanism. With 35-day PITR retention, the recovery window is
generous, but the team must have an alert on "EventLog item count dropped to
0" to actually notice in time.

### Stack confusion

`Pulumi.Pulumi.getStackName()` is the source of truth for which environment
the code is running against. Use it for the prod-detection logic, not config
values (which can be missing or typoed). Document the canonical prod stack
names in the deployment guide so the `isProdStack` heuristic stays accurate.

---

## Other Resources Worth Protecting

DynamoDB is the highest-stakes resource, but the same layered approach
applies to:

- **S3 buckets** (Task buckets, code-bundle buckets) — set
  `lifecycle.preventDestroy` equivalent via Pulumi `protect`, plus
  S3 Object Lock for buckets holding compliance data.
- **SQS dead-letter queues** — losing in-flight DLQ messages means losing
  the audit trail of failed commands. `protect: true` on prod DLQs.
- **AppSync APIs** — replacing an API rotates the GraphQL endpoint URL,
  which breaks every client. `protect: true` blocks accidental rename.
- **Cognito User Pools** — losing a user pool means every user must
  re-register. Highest-impact replacement risk in the stack.

For all of these, the same `isProdStack()` heuristic in the relevant
builder is sufficient.

---

## Recommendation

Implement the framework-level pieces in this order:

1. Add `isProdStack()` helper in `Util_DynamoDb.res` (or a new
   `Util_Stack.res` if it ends up shared with other adapters).
2. Default `deletionProtectionEnabled` to `isProdStack()` in
   `makeTableArgs`. This is the highest-leverage change — one line in the
   framework, applies to every existing and future table.
3. Default `protect: true` in `Util_DynamoDb.makeTable` and
   `Util_DynamoDbStream.makeTable` opts when `isProdStack()`.
4. Apply the same pattern to `Util.S3.makeBucket`, AppSync API creation,
   and Cognito User Pool creation.
5. Document the unprotect/wipe workflow as the inverse of this document —
   the existing `clearing-aws-eventlog-querydb-tables.md` already covers
   most of it; add a section pointing at this analysis as the precondition
   for the wipe procedure.
6. Publish the recommended IAM policy template for layer 4 in the
   deployment guide.

The framework changes are small and reversible. The behavioural change for
operators is significant: prod wipes now require an explicit two-step
unprotect, which is exactly the friction the system was missing.
