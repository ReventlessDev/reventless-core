let invalidNameChars = [%re "/[^.\-_a-zA-Z0-9]/g"];

let validateName = Js.String2.replaceByRe(_, invalidNameChars, "_");
