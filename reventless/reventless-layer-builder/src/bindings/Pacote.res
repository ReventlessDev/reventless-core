type extractResult

type config
external makeConfig: dict<string> => config = "%identity"

@module("pacote")
external extract: (string, string, config) => promise<extractResult> = "extract"
