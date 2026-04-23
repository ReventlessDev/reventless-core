#!/usr/bin/env node
// Thin launcher for the reventless-gwt CLI. The heavy lifting lives in
// Cli.res — this file only resolves the compiled module and exits with the
// code Cli.main returns.

import { main } from "../src/Cli.res.mjs";

main()
  .then((code) => process.exit(typeof code === "number" ? code : 0))
  .catch((err) => {
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
  });
