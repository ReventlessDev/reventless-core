@module("node:path") @variadic
external resolve: array<string> => string = "resolve"

@module("node:path") @variadic
external join: array<string> => string = "join"

@module("node:path")
external dirname: string => string = "dirname"
