let invalidNameChars = [%re "/[^.\-_a-zA-Z0-9]/g"];

let validateName = Js.String2.replaceByRe(_, invalidNameChars, "_");

// Example ARN: arn:aws:sqs:eu-west-1:xxxxxx:MarketplaceServiceExtensionPointCommandTopic-0101023
let arn2Name: string => string =
  arn =>
    arn
    ->Js.String2.split(":")
    ->Belt.Array.get(5)
    ->Belt.Option.getWithDefault("unknown");
