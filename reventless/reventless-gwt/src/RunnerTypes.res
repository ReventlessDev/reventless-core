// Shared data types between the runner loop and formatters.

type testStatus = Pass | Fail | Skip

type testResult = {
  id: string,
  name: string,
  describePath: array<string>,
  status: testStatus,
  durationMs: float,
  location: option<Collector.location>,
  slice: option<string>,
  mismatch: option<Outcome.mismatch>,
  skipReason: option<string>,
}

type fileResult = {
  path: string,
  tests: array<testResult>,
}

type summary = {
  total: int,
  passed: int,
  failed: int,
  skipped: int,
  files: int,
  durationMs: float,
  startedAt: string,
}

type runResult = {
  summary: summary,
  files: array<fileResult>,
}

let statusString = (s: testStatus) =>
  switch s {
  | Pass => "pass"
  | Fail => "fail"
  | Skip => "skip"
  }

let summaryOf = (files: array<fileResult>, durationMs: float, startedAt: string): summary => {
  let total = ref(0)
  let passed = ref(0)
  let failed = ref(0)
  let skipped = ref(0)
  files->Array.forEach(f =>
    f.tests->Array.forEach(t => {
      total := total.contents + 1
      switch t.status {
      | Pass => passed := passed.contents + 1
      | Fail => failed := failed.contents + 1
      | Skip => skipped := skipped.contents + 1
      }
    })
  )
  {
    total: total.contents,
    passed: passed.contents,
    failed: failed.contents,
    skipped: skipped.contents,
    files: files->Array.length,
    durationMs,
    startedAt,
  }
}
