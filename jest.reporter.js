const path = require("path");

const green = "\x1b[32m";
const red = "\x1b[31m";
const bold = "\x1b[1m";
const dim = "\x1b[2m";
const reset = "\x1b[0m";

class CompactReporter {
  constructor(globalConfig) {
    this._globalConfig = globalConfig;
  }

  onTestResult(test, testResult) {
    const failed = testResult.numFailingTests > 0;
    const status = failed ? `${red}${bold}FAIL${reset}` : `${green}${bold}PASS${reset}`;

    const displayName = test.context.config.displayName;
    const projectName = typeof displayName === "string" ? displayName : displayName?.name ?? "";

    const basename = path.basename(testResult.testFilePath);
    const name = basename.split(".")[0];

    const total = testResult.numPassingTests + testResult.numFailingTests + testResult.numPendingTests;
    const duration = ((testResult.perfStats.end - testResult.perfStats.start) / 1000).toFixed(3);
    const stats = failed
      ? `${red}${testResult.numFailingTests} failed${reset}, ${testResult.numPassingTests} passed, ${total} total, ${duration}s`
      : `${dim}${total} tests, ${duration}s${reset}`;

    if (process.env.ONLY_FAILURES === "1" && !failed) return;

    process.stdout.write(`${status} ${dim}${projectName}${reset} ${name} ${dim}(${reset}${stats}${dim})${reset}\n`);

    if (failed) {
      for (const r of testResult.testResults.filter((r) => r.status === "failed")) {
        process.stdout.write(`  ${red}✕${reset} ${r.fullName}\n`);
        for (const msg of r.failureMessages) {
          for (const line of msg.split("\n").slice(0, 20)) {
            process.stdout.write(`    ${line}\n`);
          }
        }
      }
    }
  }

  onRunComplete(_contexts, results) {
    const failedSuites = results.numFailedTestSuites > 0 ? `${red}${bold}${results.numFailedTestSuites} failed${reset}, ` : "";
    const failedTests = results.numFailedTests > 0 ? `${red}${bold}${results.numFailedTests} failed${reset}, ` : "";
    const elapsed = ((Date.now() - results.startTime) / 1000).toFixed(3);

    process.stdout.write("\n");
    process.stdout.write(`Test Suites: ${failedSuites}${green}${results.numPassedTestSuites} passed${reset}, ${results.numTotalTestSuites} total\n`);
    process.stdout.write(`Tests:       ${failedTests}${green}${results.numPassedTests} passed${reset}, ${results.numTotalTests} total\n`);
    process.stdout.write(`Time:        ${elapsed} s\n`);
  }
}

module.exports = CompactReporter;
