type t

type config = {connectionTimeout: int, requestTimeout: int}

@new @module("@smithy/node-http-handler")
external make: config => t = "NodeHttpHandler"
