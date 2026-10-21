#!/usr/bin/env node
// List British spellings in the docs' prose, so they can be fixed before a docs commit.
//
// The prose is American, matching the identifiers. This covers the words that
// drifted (behaviour, honour, favour, colour, recognise, organise, licence,
// catalogue, modelling and their inflections) in the Markdown under docs/ and
// packages/doc, CLAUDE.md and .claude/rules/. Run by hand; not wired to CI.
//
// Skipped, because changing them would change something that is not prose:
// fenced code, inline code, link targets, URLs, HTML tags, double-quoted text,
// and words that look like identifiers (an inner capital, `_`, `.`, `/`, a digit).
// ALLOWED lists the few places that keep the British spelling on purpose.
//
// Exit code 1 when anything is listed.

import {execFileSync} from "node:child_process"
import {readFileSync} from "node:fs"

const BRITISH =
  /[Bb]ehaviour|[Hh]onour|[Ff]avour|[Cc]olour|[Rr]ecognis(?:e|ed|es|ing|able|ably|ation|ers?)\b|[Oo]rganis(?:e|ed|es|ing|ations?|ational|ers?)\b|[Ll]icences?\b|[Cc]atalogu(?:e|es|ed|ing)\b|[Mm]odell(?:ing|ed|ers?)\b/

// [file, why] for a whole file; [file, why, text] for one line containing `text`.
const ALLOWED = [
  ["docs/plans/done/behaviour-to-behavior-rename-plan.md", "its subject is the spelling"],
  [
    "docs/analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md",
    "names the British spellings it counts",
  ],
  ["docs/plans/framework-vocabulary-cleanups.md", "names the British spellings it replaces"],
  [
    "docs/plans/done/the-shell-knows-its-environment.md",
    "other repositories link to this heading's anchor",
    "honours",
  ],
]

const files = execFileSync(
  "git",
  ["ls-files", "--cached", "--others", "--exclude-standard", "--", "docs/*.md", "docs/*.mdx", "packages/doc/*.md", "packages/doc/*.mdx", "CLAUDE.md", ".claude/rules/*.md"],
  {encoding: "utf8"},
)
  .split("\n")
  .filter(f => f && !f.endsWith("CHANGELOG.md"))

const SKIP = /(`+)[^`]*?\1|\]\([^)]*\)|^\s*\[[^\]]+\]:\s*\S+|https?:\/\/\S+|<[^>\n]+>|"[^"\n]*"|“[^”\n]*”|\{#[^}]*\}/g
const TOKEN = /[A-Za-z0-9_./\\-]+/g

const identifierLike = tok =>
  /[_./\\0-9]/.test(tok) || tok.split("-").some(part => /[A-Z]/.test(part.slice(1)))

const britishWords = text =>
  [...text.replace(SKIP, " ").matchAll(TOKEN)]
    .map(m => m[0].replace(/[.-]+$/, ""))
    .filter(tok => BRITISH.test(tok) && !identifierLike(tok))

const hits = []
for (const file of files) {
  const wholeFile = ALLOWED.some(([f, , text]) => f === file && text === undefined)
  if (wholeFile) continue
  let fence = null
  readFileSync(file, "utf8")
    .split("\n")
    .forEach((line, i) => {
      const open = line.trimStart().match(/^(`{3,}|~{3,})/)
      if (fence) {
        if (open && open[1][0] === fence[0] && open[1].length >= fence.length) fence = null
        return
      }
      if (open) {
        fence = open[1]
        return
      }
      const words = britishWords(line)
      if (words.length === 0) return
      if (ALLOWED.some(([f, , text]) => f === file && text !== undefined && line.includes(text))) return
      hits.push(`${file}:${i + 1}: ${words.join(", ")}`)
    })
}

if (hits.length > 0) {
  console.log(hits.join("\n"))
  console.log(`\n${hits.length} line(s) with a British spelling. Use the American one.`)
  process.exit(1)
}
console.log(`check:spelling: ${files.length} files, no British spellings.`)
