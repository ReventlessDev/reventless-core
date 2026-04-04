const path = require("path");
const fs = require("fs");

const installMacLinuxBinary = (binary) => {
  const source = path.join(__dirname, binary);
  if (fs.existsSync(source)) {
    const target = path.join(__dirname, "bin");
    fs.renameSync(source, target);
    fs.chmodSync(target, 0o777);
  }
};

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

switch (process.platform) {
  case "linux":
    installMacLinuxBinary(
      process.arch === "arm64" ? "ppx-linux-arm.exe" : "ppx-linux.exe"
    );
    break;
  case "darwin":
    const binaryName =
      process.arch === "x64" ? "ppx-osx-x64.exe" : "ppx-osx.exe";
    installMacLinuxBinary(binaryName);
    break;
  case "win32":
    installWindowsBinary();
    break;
}
