@module("node:fs")
external existsSync: string => bool = "existsSync"

type cpOptions = {recursive?: bool}

@module("node:fs")
external cpSync: (string, string, cpOptions) => unit = "cpSync"
