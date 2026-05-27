#!/usr/bin/env python3
"""
find-orphans.py — Identify AWS resources that match this project's naming
patterns but are NOT tracked by any of the given Pulumi stack states.

Background
----------
The online-shop-hybrid stack is split into three Pulumi projects:
  examples/online-shop-hybrid/platform-aws/   (admin, scheduler, shared API)
  examples/online-shop-hybrid/catalog-aws/    (Catalog plugin infra)
  examples/online-shop-hybrid/ordering-aws/   (Ordering plugin infra)

A stack split in 2026-05-21 left a lot of orphan AWS resources from the
prior monolithic stack. Subsequent IAM-role-driven Lambda replacements
have added more. This script identifies them and emits delete commands.

Usage
-----
  # 1. Export each stack's state
  cd examples/online-shop-hybrid/platform-aws && pulumi stack export --file /tmp/state-platform.json
  cd examples/online-shop-hybrid/catalog-aws  && pulumi stack export --file /tmp/state-catalog.json
  cd examples/online-shop-hybrid/ordering-aws && pulumi stack export --file /tmp/state-ordering.json

  # 2. List orphans (read-only)
  python3 scripts/find-orphans.py --region eu-west-1 \\
      --state /tmp/state-platform.json /tmp/state-catalog.json /tmp/state-ordering.json

  # 3. Generate delete commands in safe dependency order (still prints to stdout — does NOT execute)
  python3 scripts/find-orphans.py --region eu-west-1 \\
      --state /tmp/state-platform.json /tmp/state-catalog.json /tmp/state-ordering.json \\
      --delete-commands

Identification rule
-------------------
An AWS resource is flagged as orphan when:
  - its physical name matches the Pulumi auto-suffix pattern "<base>-<6-8 hex>" (optional .fifo)
  - "<base>" matches a base name derived from at least one tracked resource
  - the full physical name does NOT appear in any state's tracked set

Types checked
-------------
  - aws:lambda/function           (lambda)
  - aws:sqs/queue                 (sqs)
  - aws:sns/topic                 (sns)
  - aws:dynamodb/table            (dynamodb)
  - aws:cloudwatch/logGroup       (logs, derived from tracked Lambda names)
  - lambda event-source-mappings  (esm, derived per orphan Lambda)

Not checked (riskier; review manually)
--------------------------------------
  - aws:iam/role
  - EventBridge rules / EventBridge Scheduler schedules
  - AppSync APIs / data sources / resolvers
  - CloudFront / S3 / Cognito
"""

import argparse
import json
import re
import subprocess
import sys

SUFFIX_RE = re.compile(r"^(.+?)-[a-f0-9]{6,8}(?:\.fifo)?$")


def base_of(name):
    """Return the base name (suffix stripped) if name matches the auto-suffix pattern; else None."""
    if not name:
        return None
    m = SUFFIX_RE.match(name)
    return m.group(1) if m else None


# Resource-type config table. Each entry knows how to:
#  - identify its Pulumi resource type(s)
#  - extract a physical name from a state resource
#  - list all such resources in AWS
#  - emit a delete command for a given physical name
TYPES = {
    "lambda": {
        "pulumi_types": ("aws:lambda/function:Function",),
        "phys": lambda r: r.get("outputs", {}).get("name"),
        "list_cmd": lambda region: [
            "aws", "--region", region, "lambda", "list-functions",
            "--query", "Functions[].FunctionName", "--output", "json",
        ],
        "delete_cmd": lambda region, name: (
            f"aws --region {region} lambda delete-function --function-name {name}"
        ),
    },
    "sqs": {
        "pulumi_types": ("aws:sqs/queue:Queue",),
        "phys": lambda r: ((r.get("outputs", {}).get("url", "") or "").rsplit("/", 1)[-1]) or None,
        "list_cmd": lambda region: [
            "aws", "--region", region, "sqs", "list-queues",
            "--query", "QueueUrls", "--output", "json",
        ],
        "post_list": lambda urls: [u.rsplit("/", 1)[-1] for u in (urls or [])],
        "delete_cmd": lambda region, name: (
            f"aws --region {region} sqs delete-queue --queue-url "
            f"$(aws --region {region} sqs get-queue-url --queue-name {name} --query QueueUrl --output text)"
        ),
    },
    "sns": {
        "pulumi_types": ("aws:sns/topic:Topic",),
        "phys": lambda r: r.get("outputs", {}).get("name"),
        "list_cmd": lambda region: [
            "aws", "--region", region, "sns", "list-topics",
            "--query", "Topics[].TopicArn", "--output", "json",
        ],
        "post_list": lambda arns: [a.rsplit(":", 1)[-1] for a in (arns or [])],
        "delete_cmd": lambda region, name: (
            f"aws --region {region} sns delete-topic --topic-arn "
            f"$(aws --region {region} sns list-topics "
            f"--query \"Topics[?ends_with(TopicArn, ':{name}')].TopicArn | [0]\" --output text)"
        ),
    },
    "dynamodb": {
        "pulumi_types": (
            "aws:dynamodb/table:Table",
            "aws-native:dynamodb:Table",
        ),
        "phys": lambda r: (
            r.get("outputs", {}).get("name")
            or r.get("outputs", {}).get("TableName")
        ),
        "list_cmd": lambda region: [
            "aws", "--region", region, "dynamodb", "list-tables",
            "--query", "TableNames", "--output", "json",
        ],
        "delete_cmd": lambda region, name: (
            f"aws --region {region} dynamodb delete-table --table-name {name}"
        ),
    },
    "logs": {
        # Log groups are 1:1 with Lambdas (Pulumi typically doesn't track them
        # explicitly). We derive the "tracked" log-group set from tracked Lambda
        # names: /aws/lambda/<lambda-name>.
        "pulumi_types": (),  # special-cased
        "list_cmd": lambda region: [
            "aws", "--region", region, "logs", "describe-log-groups",
            "--query", "logGroups[].logGroupName", "--output", "json",
        ],
        "delete_cmd": lambda region, name: (
            f"aws --region {region} logs delete-log-group --log-group-name {name}"
        ),
    },
}


def load_states(paths):
    return [json.load(open(p)) for p in paths]


def tracked_phys(states, type_key):
    info = TYPES[type_key]
    phys = set()
    for st in states:
        for r in st.get("deployment", {}).get("resources", []):
            if r.get("type") in info["pulumi_types"]:
                p = info["phys"](r)
                if p:
                    phys.add(p)
    return phys


def list_aws(type_key, region):
    info = TYPES[type_key]
    out = subprocess.run(info["list_cmd"](region), capture_output=True, text=True, check=True)
    raw = json.loads(out.stdout) if out.stdout.strip() else []
    if "post_list" in info:
        return info["post_list"](raw)
    return raw


def base_names_from(names):
    return {b for b in (base_of(n) for n in names) if b}


def find_orphans(aws_names, tracked, bases, type_key):
    orphans = []
    for n in aws_names:
        if n in tracked:
            continue
        check = n[len("/aws/lambda/"):] if type_key == "logs" and n.startswith("/aws/lambda/") else n
        b = base_of(check)
        if b and b in bases:
            orphans.append(n)
    return orphans


def list_event_source_mappings_for(function_name, region):
    """Return list of (uuid, event_source_arn) for the given function."""
    out = subprocess.run(
        ["aws", "--region", region, "lambda", "list-event-source-mappings",
         "--function-name", function_name,
         "--query", "EventSourceMappings[].[UUID,EventSourceArn]",
         "--output", "json"],
        capture_output=True, text=True, check=False,
    )
    if out.returncode != 0:
        return []
    try:
        return json.loads(out.stdout) if out.stdout.strip() else []
    except json.JSONDecodeError:
        return []


def collect_orphans(states, region, types):
    """Return a dict {type_key: [orphan_names]} plus a list of event-source-mapping UUIDs."""
    results = {}
    tracked_by_type = {}

    tracked_by_type["lambda"] = tracked_phys(states, "lambda")
    tracked_lambdas = tracked_by_type["lambda"]
    tracked_by_type["logs"] = {f"/aws/lambda/{n}" for n in tracked_lambdas}

    for tk in types:
        if tk not in TYPES:
            print(f"# unknown type: {tk}", file=sys.stderr)
            continue
        if tk == "logs":
            tracked = tracked_by_type["logs"]
            bases = base_names_from(tracked_lambdas)
        else:
            tracked = tracked_by_type.get(tk) or tracked_phys(states, tk)
            tracked_by_type[tk] = tracked
            bases = base_names_from(tracked)
        if not bases:
            results[tk] = []
            continue
        aws_names = list_aws(tk, region)
        results[tk] = (find_orphans(aws_names, tracked, bases, tk), len(aws_names), len(tracked), sorted(bases))
    return results, tracked_by_type


def find_esm_for_orphan_lambdas(orphan_lambdas, region):
    """Return list of dicts: {uuid, arn, function} for every event-source-mapping
    on an orphan Lambda."""
    mappings = []
    for fn in orphan_lambdas:
        for uuid, arn in list_event_source_mappings_for(fn, region):
            mappings.append({"uuid": uuid, "arn": arn, "function": fn})
    return mappings


def main():
    ap = argparse.ArgumentParser(formatter_class=argparse.RawDescriptionHelpFormatter,
                                 description=__doc__)
    ap.add_argument("--region", default="eu-west-1")
    ap.add_argument("--state", nargs="+", required=True,
                    help="Paths to pulumi stack export JSON files")
    ap.add_argument("--types", default="lambda,sqs,sns,dynamodb,logs",
                    help="Comma-separated types to check (default: lambda,sqs,sns,dynamodb,logs)")
    ap.add_argument("--delete-commands", action="store_true",
                    help="Emit aws delete-* commands in dependency-safe order (still does not execute)")
    args = ap.parse_args()

    states = load_states(args.state)
    types = args.types.split(",")

    results, tracked_by_type = collect_orphans(states, args.region, types)

    # Find ESM bound to orphan Lambdas (only if lambda was checked)
    orphan_lambdas = results.get("lambda", ([], 0, 0, []))[0] if "lambda" in results else []
    esms = find_esm_for_orphan_lambdas(orphan_lambdas, args.region) if orphan_lambdas else []

    # --- Audit phase: print summary ---
    print("# === orphan audit ===")
    total = 0
    for tk in types:
        if tk not in results:
            continue
        orphans, aws_n, tracked_n, bases = results[tk]
        print(f"\n## {tk}: aws={aws_n}  tracked={tracked_n}  orphans={len(orphans)}")
        print(f"# base names: {bases}")
        for o in sorted(orphans):
            print(f"  {o}")
        total += len(orphans)

    if esms:
        print(f"\n## event-source-mappings on orphan lambdas: {len(esms)}")
        for m in esms:
            print(f"  uuid={m['uuid']}  fn={m['function']}  source={m['arn']}")

    print(f"\n# === total orphans across types: {total} (+ {len(esms)} event-source-mappings) ===")

    if not args.delete_commands:
        return

    # --- Delete phase: emit commands in dependency-safe order ---
    print("\n# ============================================================")
    print("# delete commands (REVIEW BEFORE RUNNING)")
    print("# ")
    print("# Safe deletion order:")
    print("#   1. lambda event-source-mappings  (stop new invocations)")
    print("#   2. lambda functions              (free the event-source bindings)")
    print("#   3. sqs queues                    (Lambda no longer polls them)")
    print("#   4. sns topics                    (no subscribers left to nag)")
    print("#   5. dynamodb tables               (irreversible — data gone)")
    print("#   6. cloudwatch log groups         (last, to preserve crash logs)")
    print("# ")
    print("# Not handled here (do manually if needed):")
    print("#   - IAM roles + role policies for the orphan Lambdas")
    print("#   - EventBridge rules / EventBridge Scheduler schedules")
    print("#   - AppSync resolvers / data sources")
    print("# ============================================================\n")

    # 1. ESMs
    if esms:
        print("# --- step 1: delete event-source-mappings on orphan lambdas ---")
        for m in esms:
            print(f"aws --region {args.region} lambda delete-event-source-mapping --uuid {m['uuid']}")
        print()

    # 2-6: ordered types
    order = ["lambda", "sqs", "sns", "dynamodb", "logs"]
    step_names = {
        "lambda": "step 2: delete orphan lambda functions",
        "sqs": "step 3: delete orphan SQS queues",
        "sns": "step 4: delete orphan SNS topics",
        "dynamodb": "step 5: delete orphan DynamoDB tables (IRREVERSIBLE — verify each is empty/unwanted first)",
        "logs": "step 6: delete orphan CloudWatch log groups",
    }
    for tk in order:
        if tk not in results:
            continue
        orphans = results[tk][0]
        if not orphans:
            continue
        print(f"# --- {step_names[tk]} ---")
        for o in sorted(orphans):
            print(TYPES[tk]["delete_cmd"](args.region, o))
        print()


if __name__ == "__main__":
    main()
