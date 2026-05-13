# Clearing EventLog and QueryDb Tables on AWS

## Context

We are redesigning the `EventLog` structure (also affects `DcbEventLog`) and need to wipe all
legacy data from the deployed AWS environment before re-testing against the new schema.

Tables involved on AWS:

- **EventLog** — `Util_DynamoDbStream.makeTable` in `EventLogStorage_DynamoDb.res`
  (aggregate event-sourcing log + DynamoDB Stream → EventTopic).
- **DcbEventLog** — `Util_DynamoDbStream.makeTable` in `DcbEventLogStorage_DynamoDb.res`
  (DCB event log with `(id, position)` key + DynamoDB Stream).
- **QueryDb** — `QueryDbStorage_DynamoDb.res` (per-read-model projection tables, may include
  GSIs). One QueryDb table per ReadModel.

All tables are created and named by Pulumi as part of the stack. Names are stack/project
prefixed (e.g. `<plugin>-<readModel>QueryDB-<hash>`).

## Options Ranked by Effort / Blast Radius

### 1. `pulumi destroy --target <tableUrn>` then `pulumi up` ← **recommended**

For each table resource:

```bash
pulumi destroy --target 'urn:pulumi:<stack>::<project>::aws:dynamodb/table:Table::<name>'
pulumi up
```

Pros:
- Pulumi state stays consistent — no manual `refresh` needed.
- Schema redesign is normally accompanied by Pulumi code changes anyway; the new `pulumi up`
  recreates the tables with the new keys/GSIs in one step.
- Targeted: only tables (and their direct dependents — Lambda event-source mappings on
  streams) are touched. AppSync, SQS, SNS, Lambdas remain.

Cons:
- Need to enumerate the table URNs. Get them once with:
  ```bash
  pulumi stack --show-urns | grep 'aws:dynamodb/table:Table'
  ```
- Lambda event-source mappings tied to the DynamoDB Stream are replaced (Pulumi handles this
  automatically; allow ~1 min per mapping).

### 2. `aws dynamodb delete-table` per table, then `pulumi up`

```bash
# List all tables created by this stack (adjust prefix to your stack/project naming)
aws dynamodb list-tables --query 'TableNames[?starts_with(@, `<stack-prefix>`)]' --output text

# Delete each one (parallel; deletion is async — full removal takes ~30–60 s per table)
for t in $(aws dynamodb list-tables --query 'TableNames[?starts_with(@, `<stack-prefix>`)]' --output text); do
  aws dynamodb delete-table --table-name "$t"
done

# Wait until none of them appear anymore, then:
pulumi refresh --yes        # sync state to reality (Pulumi will mark tables as deleted)
pulumi up                   # recreate
```

Pros:
- Fastest to type if you don't have URNs handy.
- Works regardless of upstream Pulumi changes.

Cons:
- `pulumi refresh` is mandatory; skipping it leaves Pulumi state thinking the tables exist.
- Lambda event-source mappings on the streams enter a broken state until `pulumi up`
  recreates them.

### 3. Full `pulumi destroy` of the stack + `pulumi up`

```bash
pulumi destroy --yes
pulumi up --yes
```

Pros:
- Absolutely clean slate — zero stale data anywhere.
- One command.

Cons:
- Tears down everything: AppSync APIs, Lambdas, SQS/SNS, IAM, S3 task buckets. For
  development/test stacks this is fine; for shared environments it is overkill.
- AppSync recreation is the slow part (~5–10 min on a real stack).

### 4. Resource-name change (force replace) inside Pulumi code

Rename the table resource (e.g. `EventLogTable` → `EventLogTableV2`) in ReScript code, then
`pulumi up`. Pulumi deletes the old and creates a new one as part of the deploy.

Pros:
- Folds the wipe into the schema-change PR — single deploy.

Cons:
- Renames every reference (stream ARN, GSI names baked into IAM, etc.). Risky unless the
  redesign already requires a Pulumi rename anyway.
- Logical resource name lives in Pulumi state — easy to forget to rename back later.

### 5. Scan + `BatchWriteItem` delete (keep table, wipe rows)

```bash
aws dynamodb scan --table-name <t> --projection-expression "id,#p" \
   --expression-attribute-names '{"#p":"position"}' --output json \
   | jq -c '.Items[] | {DeleteRequest:{Key:.}}' \
   | <chunk 25 / batch-write loop>
```

Pros:
- Preserves table config, GSIs, IAM, stream attachments. No Pulumi work.

Cons:
- Only useful if the schema is **not** changing. We are redesigning the structure, so the old
  rows would not fit the new key schema anyway — wasted work.
- Slow and costs read+write capacity for the full table scan + delete.
- DynamoDB has no native `TRUNCATE`.

### 6. TTL-based purge

Set `reventlessPurgeTime` (already configured as the TTL attribute via
`Util_DynamoDb_Runtime.purgeTimeAttributeName`) to a past Unix timestamp on every item.
DynamoDB removes them within ~48 hours.

Cons:
- Way too slow for "wipe before testing". Mentioned only for completeness — useful for
  routine garbage collection, not for a one-shot redesign wipe.

## Recommendation

Use **Option 1** (`pulumi destroy --target` + `pulumi up`). Concrete recipe:

```bash
# 1. Identify tables in this stack
pulumi stack --show-urns | grep 'aws:dynamodb/table:Table' > /tmp/tables.txt

# 2. Destroy each (review the list first!)
while read urn; do
  pulumi destroy --target "$urn" --yes
done < /tmp/tables.txt

# 3. Bring the stack back with the new EventLog code already merged
pulumi up --yes
```

This is the easiest path that:
- Wipes all rows.
- Picks up the new EventLog schema automatically on recreate.
- Leaves AppSync / Lambda / messaging intact (fast turnaround for subsequent tests).
- Keeps Pulumi state consistent without manual `refresh`.

If the stack is a personal dev sandbox with no other consumers, **Option 3** (full
`pulumi destroy` + `pulumi up`) is even simpler and worth it for the certainty of a clean
slate — at the cost of ~10 min of redeploy time.

## After the Wipe — Verification Checklist

1. `aws dynamodb scan --table-name <t> --select COUNT` returns `Count: 0` on each table.
2. Lambda event-source mappings for the DynamoDB Streams are `Enabled` (check in the AWS
   console or `aws lambda list-event-source-mappings`).
3. Run the existing E2E suite against the deployed stack to confirm the new EventLog schema
   accepts writes and replay works end-to-end.

## Appendix — Automating DynamoDB Table Deletion

> ⚠️ **Warning:** `aws dynamodb list-tables` returns **every table in the AWS
> account/region**, not just the ones from your stack. An unfiltered delete loop is
> irreversible and will wipe unrelated work. **Always filter by stack prefix or tag.**

### Option A — Filter by name prefix

```bash
# 1. Dry-run: list what would be deleted
PREFIX="<your-stack-prefix>"   # e.g. "online-shop-dev-"
REGION="eu-west-1"

aws dynamodb list-tables --region "$REGION" --output text --query 'TableNames[]' \
  | tr '\t' '\n' \
  | grep "^$PREFIX" \
  | tee /tmp/tables-to-delete.txt

# 2. Inspect /tmp/tables-to-delete.txt — confirm the list is correct.

# 3. Delete in parallel (xargs -P 10)
xargs -P 10 -I {} aws dynamodb delete-table --region "$REGION" --table-name {} \
  < /tmp/tables-to-delete.txt

# 4. Wait until every table is fully gone (delete-table is async, ~30–60 s per table)
while read t; do
  aws dynamodb wait table-not-exists --region "$REGION" --table-name "$t"
done < /tmp/tables-to-delete.txt
```

### Option B — Filter by Pulumi tag (preferred — survives naming changes)

The Reventless AWS adapter tags resources via Pulumi defaults, so filtering by
`pulumi-stack` is more robust than prefix matching:

```bash
REGION="eu-west-1"
STACK="<pulumi-stack-name>"

aws resourcegroupstaggingapi get-resources \
  --region "$REGION" \
  --resource-type-filters dynamodb:table \
  --tag-filters "Key=pulumi-stack,Values=$STACK" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text \
  | tr '\t' '\n' \
  | awk -F/ '{print $NF}' \
  > /tmp/tables-to-delete.txt
```

Then use the same `xargs` + `wait` loop as Option A.

### Option C — Wipe every table in the account (sandbox only!)

```bash
# DESTRUCTIVE — no filter. Only run this in a throwaway AWS account.
REGION="eu-west-1"
aws dynamodb list-tables --region "$REGION" --output text --query 'TableNames[]' \
  | tr '\t' '\n' \
  | xargs -P 10 -I {} aws dynamodb delete-table --region "$REGION" --table-name {}
```

### Reconcile Pulumi state after a CLI-driven delete

Pulumi still believes the tables exist. Without reconciliation, the next `pulumi up` fails
with "resource not found":

```bash
pulumi refresh --yes   # sync state with reality (tables marked deleted)
pulumi up --yes        # recreate with the new EventLog schema
```

This step is **not** needed when you use `pulumi destroy --target <tableUrn>` (Option 1 in
the main recommendation), because Pulumi performs the delete itself and keeps state in sync.
