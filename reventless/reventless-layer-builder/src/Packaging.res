module type T = {
  let package: (~sourceDir: string, ~destPath: string) => promise<unit>
  let publish: (~artifactPath: string) => promise<unit>
}
