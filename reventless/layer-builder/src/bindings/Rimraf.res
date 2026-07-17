type globOptions = {cwd: string}

type options = {glob: globOptions}

@module("rimraf")
external rimraf: string => promise<unit> = "rimraf"

@module("rimraf")
external rimrafWithOptions: (string, options) => promise<unit> = "rimraf"

@module("rimraf")
external rimrafMany: array<string> => promise<unit> = "rimraf"
