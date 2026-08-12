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
    // A suite that never got as far as running — an unresolvable import, a
    // syntax error, a file that registered no tests — reports zero *failing*
    // tests, because none ran. Counting only `numFailingTests` printed every
    // one of those as PASS with "0 tests", so a run could read green line by
    // line while the summary underneath said 68 suites failed. The reason for
    // the failure was discarded entirely.
    const execError = testResult.testExecError !== undefined;
    const failed = testResult.numFailingTests > 0 || execError;
    const status = failed ? `${red}${bold}FAIL${reset}` : `${green}${bold}PASS${reset}`;

    const displayName = test.context.config.displayName;
    const projectName = typeof displayName === "string" ? displayName : displayName?.name ?? "";

    const basename = path.basename(testResult.testFilePath);
    const name = basename.split(".")[0];

    const total = testResult.numPassingTests + testResult.numFailingTests + testResult.numPendingTests;
    const duration = ((testResult.perfStats.end - testResult.perfStats.start) / 1000).toFixed(3);
    // "0 failed, 0 passed, 0 total" is a true but useless description of a
    // suite that never ran; say that instead.
    const stats = execError
      ? `${red}suite did not run${reset}${dim}, ${duration}s${reset}`
      : failed
      ? `${red}${testResult.numFailingTests} failed${reset}, ${testResult.numPassingTests} passed, ${total} total, ${duration}s`
      : `${dim}${total} tests, ${duration}s${reset}`;

    if (process.env.ONLY_FAILURES === "1" && !failed) return;

    process.stdout.write(`${status} ${dim}${projectName}${reset} ${name} ${dim}(${reset}${stats}${dim})${reset}\n`);

    if (failed) {
      const failedTests = testResult.testResults.filter((r) => r.status === "failed");
      for (const r of failedTests) {
        process.stdout.write(`  ${red}✕${reset} ${r.fullName}\n`);
        for (const msg of r.failureMessages) {
          for (const line of msg.split("\n").slice(0, 20)) {
            process.stdout.write(`    ${line}\n`);
          }
        }
      }
      // A suite that failed before any test ran has no per-test message to
      // print — its whole reason lives on the suite. Without this the run
      // reports that something is wrong and never says what.
      //
      // Head *and* tail, unlike the per-test messages above: Jest leads a
      // suite-level failure with ~20 lines of generic "here's what you can do"
      // advice and puts the actual error last, so a plain head truncation
      // prints the boilerplate and drops the one line worth reading.
      if (failedTests.length === 0 && testResult.failureMessage) {
        const lines = testResult.failureMessage.split("\n");
        const shown =
          lines.length <= 24
            ? lines
            : [...lines.slice(0, 12), `${dim}… ${lines.length - 24} lines${reset}`, ...lines.slice(-12)];
        for (const line of shown) {
          process.stdout.write(`    ${line}\n`);
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
