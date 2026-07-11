[![npm](https://img.shields.io/npm/v/@reventlessdev/rescript-mcp-sdk.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/rescript-mcp-sdk)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/rescript-mcp-sdk

> ⚠️ **Alpha.** APIs can change without notice between releases.
> Pin exact versions and expect breaking changes.

ReScript bindings for [`@modelcontextprotocol/sdk`](https://github.com/modelcontextprotocol/typescript-sdk), used across the [Reventless](https://docs.reventless.dev) framework. It binds `@modelcontextprotocol/sdk` `^1.29.0` (bundled dependency).

## Install

```bash
pnpm add @reventlessdev/rescript-mcp-sdk
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/rescript-mcp-sdk"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Usage

The bindings are exposed as ReScript modules:

- `McpSdk` — bindings for `@modelcontextprotocol/sdk`.
- `McpSdk_Helpers` — convenience helpers over the SDK bindings.

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)
- 🔗 Upstream — [`@modelcontextprotocol/sdk`](https://github.com/modelcontextprotocol/typescript-sdk)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
