# Reventless-Universe

This is a mono-repo, which contains all necessary packages for the Reventless framework.

For individual Readmes per package see inside the package's directory `./packages/*`:

- [rescript-aws-sdk](packages/rescript-aws-sdk/README.md): bindings for `aws-sdk`
- [rescript-fast-csv](packages/rescript-fast-csv/README.md): bindings for `fast-csv`
- [rescript-hash-obj](packages/rescript-hash-obj/README.md): bindings for `hash-obj`
- [rescript-node-streams](packages/rescript-node-streams/README.md): bindings for streams in `node`
- [bs-pulumi-aws](packages/bs-pulumi-aws/README.md): bindings for `@pulumi/pulumi-aws`
- [bs-pulumi-pulumi](packages/bs-pulumi-pulumi/README.md): bindings for `@pulumi/pulumi`
- [bs-ssh2](packages/bs-ssh2/README.md): bindings for `ssh2`
- [bs-uuid](packages/bs-uuid/README.md): bindings for `uuid`
- [reventless](packages/reventless/README.md): reventless framework (provider agnostic)
- [reventless-aws](packages/reventless-aws/README.md): aws specifics for the reventless framework (adapter, preconficured components, etc.)
- [reventless-ci](packages/reventless-ci/README.md): ci tooling for reventless projects (docker image, scripts, ci templates)
- [reventless-spec](packages/reventless-spec/README.md): types & interface files for the reventless framework
- [reventless-ui](packages/reventless-ui/README.md): react component library & core ui for reventless based applications

## Setup

This repo uses [Lerna](https://lerna.js.org/) to manage all the packages.

0. use a node version manager like [fnm](https://github.com/Schniz/fnm) and configure it to respect `.node_version` files *recursively* (if not present in current directory, try to traverse over parent directories to find a version file). For fnm, this can be done by setting the env var `FNM_VERSION_FILE_STRATEGY` to `recursive` (default is `local`). (see [fnm docs](https://github.com/Schniz/fnm/blob/master/docs/commands.md))
1. install general devDependencies by invoking `npm install` in the repository's root directory
2. invoke `lerna bootstrap` (if lerna is globally installed - otherwise `npm run bootstrap`) to download all dependencies of the packages in this repository and link them together
3. Done!
   You can find the separate packages inside of `./packages/PkgName`. Change to the desired directory and work on the package like you would usually do.

## Basic Usage Of Lerna

> A tool for managing JavaScript projects with multiple packages.

### Starting A New Package From Scratch

Use the [wizard](#lerna-wizard) or [`lerna create`](https://github.com/lerna/lerna/tree/master/commands/create#readme) command to create a new directory in `./packages/` and bootstrap some files (like package.json).

### Linking Local Packages

If you work on a package (`A`), and you have a local package (`D` for dependency), that you want to make use of in `A`. [Local package means `D` is developed inside of this mono-repo, managed by lerna and not necessarily published to npm]. Add `D` to the dependencies in `package.json` of `A`. (mind to match the version) Then call `lerna bootstrap` and you're done.

### Version & Publish Packages

Run `npx lerna publish`: This will check for modifications in all packages since the last version and prompt for a new version (patch, mino, major, pre-release) for each modified package and all dependents of a modified package. After user confirmation correlating tags will be created and pushed, while the packges will also be published to the registry.

If you only want to version, but not publish packages, run `npx lerna version`.

### [Lerna Wizard](https://github.com/webuniverseio/lerna-wizard)

> Command line wizard for lerna

You can use the lerna wizard by running `npm run wizard` in the monorepo's root directoy. The wizard can help / guide you through the usage of lerna.

### [Lerna Update Wizard](https://github.com/Anifacted/lerna-update-wizard)

> A command line tool for bulk-updating lerna package dependencies

You can use the lerna update wizard by running `npm run update` in the monorepo's root directory. This wizard can help / guide you through manipulations of dependencies.

#### Features

- Update dependencies across packages
- Add new dependencies across packages
- Deduplicate dependencies across packages
- Add/Update multiple dependencies in one session
- Auto-generate Git branch & commit
- Non-interactive Mode

## Publish A Package In Github Registry

All the packages in this Monorepo can be published using the Github Registry. Therefore, a "Personal Access Token" with the privileges for "repo", "write:packages" and "read:packages" must be created in the "Github Settings". After that you can login into the registry on your local machine, using the following command:

```sh
npm login --registry=https://npm.pkg.github.com --scope=@reventless-universe
```

You will be prompted to enter your Github username, password and your public email. Instead of the password use the Personal Access Token you just created.

After that you are able to run `npm install @reventless-universe/<package>` and publish packages with `npm publish`.

## Publish A Package In GitLab Registry

All the packages in this Monorepo can be published using the GitLub Registry. Therefore, a "Personal Access Token" with the privilege for "api" must be created in "User Settings / Access Tokens". After that you can login into the registry on your local machine, using the following command:

```sh
npm login --registry=https://npm.pkg.github.com --scope=@reventless
```

You will be prompted to enter your Github username, password and your public email. Instead of the password use the Personal Access Token you just created.

After that you are able to run `npm install @reventless-universe/<package>` and publish packages with `npm publish`.

## Dependencies of packages in this repository

> //@TODO: This section is out of date and needs to be updated.

How to read the following table:

- packages are listed top to bottom
- dependencies are listed left to right

| Package / dep    | rescript-aws-sdk | rescript-fast-csv | rescript-hash-obj | rescript-node-streams | bs-pulumi-aws | bs-pulumi-pulumi | bs-ssh2 | bs-uuid |
| ---------------- | :--------: | :---------: | :---------: | :-------------: | :-----------: | :--------------: | :-----: | :-----: |
| rescript-aws-sdk       |            |             |             |        x        |               |                  |         |         |
| rescript-fast-csv      |            |             |             |        x        |               |                  |         |         |
| rescript-hash-obj      |            |             |             |                 |               |                  |         |         |
| rescript-node-streams  |            |             |             |                 |               |                  |         |         |
| bs-pulumi-aws    |            |             |             |                 |               |        x         |         |         |
| bs-pulumi-pulumi |            |             |             |                 |               |                  |         |         |
| bs-ssh2          |            |             |             |        x        |               |                  |         |         |
| bs-uuid          |            |             |             |                 |               |                  |         |         |
| reventless       |     x      |      x      |      x      |        x        |       x       |        x         |    x    |    x    |

Therefore there is a natural order in which package updates should be published:

| 0                | 1             | 2          |
| ---------------- | ------------- | ---------- |
| rescript-hash-obj      | rescript-aws-sdk    | reventless |
| rescript-node-streams  | rescript-fast-csv   |            |
| bs-pulumi-pulumi | bs-pulumi-aws |            |
| bs-uuid          | bs-ssh2       |            |
