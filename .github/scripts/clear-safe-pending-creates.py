#!/usr/bin/env python3
"""
Surgical replacement for `pulumi refresh --clear-pending-creates`.

Background
----------
The CI deploy step used to run:

    pulumi refresh --yes --skip-preview --clear-pending-creates --non-interactive

The --clear-pending-creates flag is unconditional: it drops EVERY pending-
create operation from state without checking whether the underlying AWS
resource actually exists. For synthetic resources (e.g. ACM
CertificateValidation, which is just a "wait for DNS validation" gate with
no AWS backing) that's safe — but for real Lambda functions, IAM roles,
SQS queues, etc. that were genuinely created in AWS before the deploy got
interrupted, clearing the marker silently orphans the AWS resource.

Repeated CI runs accumulated these orphans (see find-orphans.py audit:
116 orphans + 47 event-source-mappings as of the first run).

What this script does
---------------------
1. `pulumi cancel`        — releases any stale "deployment in progress" lock
2. inspect pending ops    — read stack export, find pendingOperations entries
3. classify each entry:
     - type matches a known-safe synthetic resource → `pulumi state delete`
     - anything else                                → fail loud, require operator
4. `pulumi refresh`       — sync state with reality

The workflow then proceeds with `pulumi up` separately.

Usage
-----
    python3 .github/scripts/clear-safe-pending-creates.py \\
        --stack alpha --cwd path/to/pulumi/project

Maintaining KNOWN_SAFE_TYPE_PATTERNS
------------------------------------
Add a Pulumi resource type to KNOWN_SAFE_TYPE_PATTERNS ONLY if it's a
synthetic resource (no AWS backing). When in doubt, fail loud — a one-time
operator intervention is cheaper than another orphan accumulating silently.
"""

import argparse
import json
import re
import subprocess
import sys

# Pulumi resource types that are SAFE to `pulumi state delete` when found
# stuck in a pending-create state. Each must be a regex matching the FULL
# Pulumi type token (3 colons), not a partial match.
KNOWN_SAFE_TYPE_PATTERNS = [
    # ACM cert validation is a synthetic "wait for DNS" gate. No AWS resource
    # is created; just a Pulumi-side timer that polls AWS. Times out at
    # 1h15m if the DNS validation record isn't propagated, which is the
    # original trigger for the unconditional --clear-pending-creates.
    r"^aws:acm/certificateValidation:CertificateValidation$",
]


def run(*args):
    """Run a subprocess, capturing output. Returns the CompletedProcess."""
    return subprocess.run(args, capture_output=True, text=True, check=False)


def is_safe(resource_type):
    return any(re.match(p, resource_type) for p in KNOWN_SAFE_TYPE_PATTERNS)


def main():
    ap = argparse.ArgumentParser(formatter_class=argparse.RawDescriptionHelpFormatter,
                                 description=__doc__)
    ap.add_argument("--stack", required=True, help="Pulumi stack name (e.g. alpha)")
    ap.add_argument("--cwd", required=True, help="Pulumi project directory")
    args = ap.parse_args()

    common = ["--stack", args.stack, "--cwd", args.cwd, "--non-interactive"]

    # 1. Cancel any in-progress deployment. Safe: only releases the cloud-
    #    side lock if a prior deploy is still marked "in progress". No-op
    #    when no deploy is locked.
    r = run("pulumi", "cancel", "--yes", *common)
    if r.returncode != 0:
        # Cancel exits non-zero when there's nothing to cancel — that's fine.
        # Log stderr at warning level for visibility.
        msg = (r.stderr or "").strip()
        if msg and "no update in progress" not in msg.lower():
            print(f"::warning::pulumi cancel: {msg}", file=sys.stderr)

    # 2. Export stack state and inspect pendingOperations.
    r = run("pulumi", "stack", "export", "--show-secrets", *common)
    if r.returncode != 0:
        print(
            f"::error::pulumi stack export failed: {r.stderr.strip()}",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        state = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        print(f"::error::could not parse stack export JSON: {e}", file=sys.stderr)
        sys.exit(1)

    pending = state.get("deployment", {}).get("pendingOperations") or []

    if not pending:
        print(f"No pending operations on stack {args.stack}.")
    else:
        print(f"Found {len(pending)} pending operation(s) on stack {args.stack}.")
        safe = []
        unsafe = []
        for op in pending:
            res = op.get("resource", {}) or {}
            urn = res.get("urn", "")
            typ = res.get("type", "")
            op_type = op.get("type", "?")
            (safe if is_safe(typ) else unsafe).append((urn, typ, op_type))

        if unsafe:
            for urn, typ, op_type in unsafe:
                print(
                    f"::error::Unknown pending {op_type} operation: {urn} "
                    f"(type={typ}). Refusing to silently clear. Either add the "
                    f"type to KNOWN_SAFE_TYPE_PATTERNS in "
                    f".github/scripts/clear-safe-pending-creates.py (only if it's "
                    f"a synthetic resource with no AWS backing), or resolve "
                    f"manually before re-running.",
                    file=sys.stderr,
                )
            sys.exit(1)

        for urn, typ, op_type in safe:
            print(
                f"::warning::Clearing safe pending {op_type}: {urn} (type={typ})"
            )
            r = run("pulumi", "state", "delete", "--yes", urn, *common)
            if r.returncode != 0:
                print(
                    f"::warning::pulumi state delete {urn} failed: "
                    f"{r.stderr.strip()}",
                    file=sys.stderr,
                )

    # 3. Refresh state. Tolerate failures (stale __provider serializations
    #    are common and `pulumi up` will heal them).
    r = run(
        "pulumi", "refresh", "--yes", "--skip-preview", *common
    )
    if r.returncode != 0:
        print(
            f"::warning::pulumi refresh had errors — proceeding with pulumi up to "
            f"self-heal stale resources. stderr: {(r.stderr or '').strip()}",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
