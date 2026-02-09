# `Reventless Documentation`
Documentation for the Reventless framework and UI components.

## Repository Structure

Reventless is split across two repositories:

- **[reventless-core](https://github.com/yourorg/reventless-core)** (this repo) - Framework core, AWS adapters, ReScript bindings
- **[reventless-ui](https://github.com/yourorg/reventless-ui)** - React UI components and routing utilities

This documentation site covers both repositories and is maintained in the core repo.

# WORK IN PROGRESS
Note: This package is currently being worked on. Everything you see here may be subject to change or incomplete.

You can find the [introduction](./docs/index.md) at `./docs/index.md`.


This website is built using [Docusaurus](https://docusaurus.io/), a modern static website generator.

### Installation

```
$ npm i
```

### Local Development

```
$ npm start
```

This command starts a local development server and opens up a browser window. Most changes are reflected live without having to restart the server.

### Build

```
$ npm run build
```

This command generates static content into the `build` directory and can be served using any static contents hosting service.

### Deployment

Using SSH:

```
$ USE_SSH=true npm run deploy
```

Not using SSH:

```
$ GIT_USER=<Your GitHub username> npm run deploy
```

If you are using GitHub pages for hosting, this command is a convenient way to build the website and push to the `gh-pages` branch.
