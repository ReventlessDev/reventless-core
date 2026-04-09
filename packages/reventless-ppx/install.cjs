const path = require("path");
const fs = require("fs");

// On Linux and macOS the `bin` shell script dispatches to the correct
// platform binary based on `uname -s`/`uname -m`. No install step needed.
//
// On Windows the shell script cannot be executed directly, so we rename
// the pre-built Windows binary to `bin.exe` which Node/npm can invoke.

const installWindowsBinary = () => {
  const source = path.join(__dirname, "ppx-windows.exe");
  if (fs.existsSync(source)) {
    const target = path.join(__dirname, "bin.exe");
    fs.renameSync(source, target);
    const windowsScript = path.join(__dirname, "bin.cmd");
    if (fs.existsSync(windowsScript)) {
      fs.unlinkSync(windowsScript);
    }
  }
};

if (process.platform === "win32") {
  installWindowsBinary();
}
