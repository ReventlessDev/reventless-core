@module("zip-a-folder")
external zip: (string, string) => promise<unit> = "zip"
