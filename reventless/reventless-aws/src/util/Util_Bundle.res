@module("./Util_Bundle.mjs")
external getModuleSpecifier: string => string = "getModuleSpecifier"

@module("./Util_Bundle.mjs")
external extractPackageName: string => string = "extractPackageName"

@module("./Util_Bundle.mjs")
external resolvePackageRoot: string => string = "resolvePackageRoot"

@module("./Util_Bundle.mjs")
external hashString: string => string = "hashString"

@module("./Util_Bundle.mjs")
external createFilteredPackageArchive: string => Pulumi.Archive.t = "createFilteredPackageArchive"

type codeArchive = {
  code: Pulumi.Archive.t,
  sourceCodeHash: string,
}

@module("./Util_Bundle.mjs")
external buildCodeArchive: (~entryPointModule: string, ~packageDirs: dict<string>) => codeArchive = "buildCodeArchive"
