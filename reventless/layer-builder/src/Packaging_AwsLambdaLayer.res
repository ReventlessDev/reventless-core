let package = async (~sourceDir, ~destPath) => {
  await ZipAFolder.zip(sourceDir, destPath)
}

let publish = async (~artifactPath as _) => {
  Console.log("AWS Lambda layer publishing is handled by CI workflow")
}
