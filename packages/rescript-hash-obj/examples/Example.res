open HashObj

//hashObject({'🦄': '🌈'}, {algorithm: 'sha1'});
//=> '3de3bc784035b559784fc276f47493d60555fba3'
/**
 Example usage:
 Hashes dictionary {"🦄": "🌈"} and will output 3de3bc784035b559784fc276f47493d60555fba3
 */
Console.log(hashDict(~dict=[("🦄", "🌈")]->Dict.fromArray, ~options={algorithm: SHA1}))
