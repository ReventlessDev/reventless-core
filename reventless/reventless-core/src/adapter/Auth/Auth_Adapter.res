// Provider-agnostic authentication adapter contract.
//
// `Provider` is implemented once per identity provider (in-memory headers,
// AWS Cognito, future Auth0/AzureAD/ApiKey…). The runtime path —
// `authenticate` — runs on every request and turns transport headers into
// an `Identity.authResult`. The deploy-time path — `make` — provisions
// whatever infrastructure the provider needs (a Cognito UserPool, a YAML
// store path, an API-key table, …) and returns a provider-specific
// `authConfig` for the rest of the platform stack to consume.

/**
Minimal transport-agnostic envelope handed to `authenticate`. Both GraphQL
(graphql-yoga on the in-memory platform and AppSync resolver context on
AWS) and MCP Streamable HTTP requests collapse into this shape so a single
`Provider` implementation serves every entry point.
*/
type requestContext = {
  headers: dict<string>,
  sourceIp?: string,
  correlationId?: string,
  userAgent?: string,
}

module type Provider = {
  /** Provider-specific deploy-time output (e.g. `{userPoolId, clientId}`
      for Cognito, `{usersFilePath}` for in-memory). Consumed by the platform
      stack to wire downstream resources such as the AppSync auth config. */
  type authConfig

  /** Read an identity (or anonymous / error) from a request. Pure
      function from the provider's perspective: no side effects beyond
      whatever HTTP fetches the provider issues (JWKS, etc.). */
  let authenticate: requestContext => promise<Reventless.Identity.authResult>

  /** Deploy-time: provision any infrastructure the provider depends on
      and return its config. In-memory implementations return a constant
      Output. */
  let make: (
    ~name: string,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => Pulumi.Output.t<authConfig>
}
