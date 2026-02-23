open Uuid
Console.log2("v1:", v1())
Console.log2("v3(dns):", v3(~name="testV3Dns", ~namespace=Namespace.dns))
Console.log2("v3(url):", v3(~name="testV3Url", ~namespace=Namespace.url))
Console.log2("v4:", v4())
Console.log2("v5(dns):", v5(~name="testV5Dns", ~namespace=Namespace.dns))
Console.log2("v5(url):", v5(~name="testV5Url", ~namespace=Namespace.url))
