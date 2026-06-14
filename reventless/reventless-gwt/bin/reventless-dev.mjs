#!/usr/bin/env node
// Thin launcher for the reventless-dev CLI (formerly reventless-gwt). The heavy lifting lives in
// Cli.res — this file only resolves the compiled module and exits with the
// code Cli.main returns.
//
// `LOG_LEVEL=silent` is the default so framework Info/Debug logs don't
// interleave with NDJSON / TAP / JUnit streams. Set `LOG_LEVEL=info` (or
// debug/warn/error) explicitly to re-enable. We use a dynamic `import()` so
// the env is applied BEFORE any ReScript module runs its top-level
// `Logger.fromEnv()` call.

if (!process.env.LOG_LEVEL) process.env.LOG_LEVEL = "silent";

const { main } = await import("../src/Cli.res.mjs");

main()
  .then((code) => process.exit(typeof code === "number" ? code : 0))
  .catch((err) => {
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
  });
