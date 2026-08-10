type extractResult

type config
external makeConfig: dict<JSON.t> => config = "%identity"

@module("pacote") @scope("default")
external extract: (string, string, config) => promise<extractResult> = "extract"
