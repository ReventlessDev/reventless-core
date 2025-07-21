open Uuid
Js.Console.log2("v1:", v1())
Js.Console.log2("v3(dns):", v3(~name="testV3Dns", ~namespace=Namespace.dns))
Js.Console.log2("v3(url):", v3(~name="testV3Url", ~namespace=Namespace.url))
Js.Console.log2("v4:", v4())
Js.Console.log2("v5(dns):", v5(~name="testV5Dns", ~namespace=Namespace.dns))
Js.Console.log2("v5(url):", v5(~name="testV5Url", ~namespace=Namespace.url))
// TODO examples for v3 & v5
