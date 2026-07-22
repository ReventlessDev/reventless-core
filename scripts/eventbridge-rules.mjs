#!/usr/bin/env node
// Report (and optionally sweep) the EventBridge rules a stack has accumulated.
//
// The plugin disconnect mechanism creates a one-shot `cron(...)` rule per
// connected plugin and deletes it when the plugin disconnects. Anything that
// breaks that delete leaks a rule permanently — EventBridge does not garbage
// collect a one-shot rule after it fires. The default quota is 300 rules per
// event bus per region; once it is hit `PutRule` fails and new disconnect
// schedules stop being created, silently, on a background path.
//
// This script exists so that ceiling is visible before it is reached, and so
// the cleanup is a reviewable predicate rather than an ad-hoc console session.
//
// Classification, by schedule expression:
//   rate(...)                        live (heartbeats) — never swept
//   cron(m h D M ? YYYY), past       stale one-shot — swept by --sweep
//   cron(m h D M ? YYYY), today//on  live disconnect schedule — kept
//   anything else (recurring cron, event pattern) — kept, reported as "other"
//
// The date comparison is day-granular, so a rule that fired earlier today is
// classified keep-side. That errs toward retention; those get swept next pass.
//
// Usage:
//   node scripts/eventbridge-rules.mjs [--region R] [--max N] [--sweep]
//
//   --region R  AWS region (default: AWS_REGION, else eu-west-1)
//   --max N     exit 1 when the total exceeds N (default 240 = 80% of quota)
//   --sweep     delete the stale rules (RemoveTargets, then DeleteRule)
//
// Without --sweep nothing is mutated. Requires the `aws` CLI and credentials.
// Writes a markdown summary to $GITHUB_STEP_SUMMARY when that is set.

import { execFileSync } from "node:child_process"
import { appendFileSync } from "node:fs"

const arg = (flag, fallback) => {
  const i = process.argv.indexOf(flag)
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback
}

const region = arg("--region", process.env.AWS_REGION || "eu-west-1")
const max = Number(arg("--max", "240"))
const sweep = process.argv.includes("--sweep")

const aws = (...args) => {
  const out = execFileSync("aws", ["events", ...args, "--region", region, "--output", "json"], {
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  })
  return out.trim() ? JSON.parse(out) : {}
}

let rules
try {
  rules = aws("list-rules").Rules ?? []
} catch (err) {
  console.error(`✖ could not list EventBridge rules in ${region}: ${err.message}`)
  process.exit(2)
}

// Day-granular: a rule is stale only once its fire date is strictly in the past.
const today = new Date()
const todayKey = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate())

const stale = []
const pending = []
const live = []
const other = []

for (const rule of rules) {
  const expr = rule.ScheduleExpression ?? ""
  if (expr.startsWith("rate(")) {
    live.push(rule)
    continue
  }
  const oneShot = /^cron\((\d+) (\d+) (\d+) (\d+) \? (\d+)\)$/.exec(expr)
  if (!oneShot) {
    other.push(rule)
    continue
  }
  const [, , , day, month, year] = oneShot.map(Number)
  const fires = Date.UTC(year, month - 1, day)
  if (Number.isNaN(fires)) other.push(rule)
  else if (fires < todayKey) stale.push(rule)
  else pending.push(rule)
}

const report = [
  `EventBridge rules in ${region}: **${rules.length}** (quota 300/bus)`,
  "",
  "| Class | Count | Disposition |",
  "|---|---|---|",
  `| one-shot cron, fire date past | ${stale.length} | stale — sweepable |`,
  `| one-shot cron, today or ahead | ${pending.length} | live disconnect schedules |`,
  `| rate(...) | ${live.length} | live (heartbeats) |`,
  `| other | ${other.length} | kept |`,
].join("\n")

console.log(report)
if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n### ${report}\n`)
}

if (!sweep) {
  if (stale.length > 0) {
    console.log(`\n${stale.length} stale rule(s). Re-run with --sweep to delete them.`)
  }
  if (rules.length > max) {
    console.error(
      `\n✖ ${rules.length} rules exceeds the ${max} threshold (quota is 300 per bus).\n` +
        `  Sweep with:  node scripts/eventbridge-rules.mjs --region ${region} --sweep\n`,
    )
    process.exit(1)
  }
  process.exit(0)
}

if (stale.length === 0) {
  console.log("\nNothing to sweep.")
  process.exit(0)
}

console.log(`\nSweeping ${stale.length} stale rule(s)…`)
let deleted = 0
const failures = []

for (const rule of stale) {
  try {
    // Targets pin a rule: DeleteRule fails while any remain.
    const targets = aws("list-targets-by-rule", "--rule", rule.Name).Targets ?? []
    if (targets.length > 0) {
      const result = aws("remove-targets", "--rule", rule.Name, "--ids", ...targets.map((t) => t.Id))
      if (result.FailedEntryCount > 0) {
        throw new Error(`remove-targets reported ${result.FailedEntryCount} failure(s)`)
      }
    }
    aws("delete-rule", "--name", rule.Name)
    deleted += 1
  } catch (err) {
    failures.push(`${rule.Name}: ${err.message}`)
  }
}

console.log(`Deleted ${deleted}, failed ${failures.length}.`)
for (const failure of failures) console.error(`  ✖ ${failure}`)
process.exit(failures.length === 0 ? 0 : 1)
