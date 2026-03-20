type t

@module("ora")
external make: unit => t = "default"

@send external start: (t, string) => t = "start"
@send external succeed: (t, ~text: string=?, unit) => t = "succeed"
@send external fail: (t, ~text: string=?, unit) => t = "fail"
@set external setSuffixText: (t, string) => unit = "suffixText"
