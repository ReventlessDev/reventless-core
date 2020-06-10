# Reventless-Universe
This is a mono-repo, which contains all necessary packages for the Reventless framework.

For individual Readmes per package see inside the package's directory `./packages/*`:

- [bs-aws-sdk](packages/bs-aws-sdk/README.md)
- [bs-fast-csv](packages/bs-fast-csv/README.md)
- [bs-hash-obj](packages/bs-hash-obj/README.md)
- [bs-node-streams](packages/bs-node-streams/README.md)
- [bs-pulumi-aws](packages/bs-pulumi-aws/README.md)
- [bs-pulumi-pulumi](packages/bs-pulumi-pulumi/README.md)
- [bs-ssh2](packages/bs-ssh2/README.md)
- [bs-uuid](packages/bs-uuid/README.md)
- [reventless](packages/reventless/README.md)

## Setup
This repo uses [Lerna](https://lerna.js.org/) to manage all the packages.

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

## Publish A Package In Git-Repo (gitpkg)
Using npm (or yarn) it is not possible (as of today) to depend on a package inside a subdirectory of a (private) git repo.
This is why we use [gitpkg](https://github.com/ramasilveyra/gitpkg): *Publish packages as git tags*  
### Gitpkg Basics
Every package should contain a script definition like:
```json
    "gitpkg": "../../node_modules/.bin/gitpkg publish"
```
There are some life-cycle scripts which would be called by gitpkg if they are set in package.json. Taken from [gitpkg/src/tasks/Publish/index.js](https://github.com/ramasilveyra/gitpkg/blob/9c02f228fd8f6a4f31d35631a9a2f95a76ca7adb/src/tasks/Publish/index.js):

* `prepublish`
* `prepublishOnly`
* `prepare`
* `publish`
* `postpublish`

It's advisable to use the `prepare` life-cycle script to clean the package directory from any build-artifacts by using:

```json
    "prepare": "rm .merlin || npm run clean"
```
Given the package is using bucklescript and a clean script defined.

When the gitpkg script is executed (actually calling `gitpkg publish`) it will:

* parse the package json file in the current directory
* move all files of the package's directory in a temporary directory
* create git tag (on current git remote if not specified otherwise) named like \<PackageName\>-\<PackageVersion\>-gitpkg (*eg: bs-node-streams-v0.0.1-gitpkg*)
* push the temporary directory to the named tag (only if tag doesn't already exists)

### Listing Tags Of A Repository
If you want to get all tags in the current git repository you can use `git tag -l` for local tags and `git ls-remote --tags` for remote tags.

### Depending On A Package Published With Gitpkg
Since packages are published as named tags in the repository it is possible to depend on them by using a git-link to specify dependency in a package.json. Previously, we used something like the following to depend on the reventless project:
```
    "reventless": "git+https://gitlab+deploy-token-59148:3FUfgP98A8vvrf26tFDU@gitlab.com/atos-austria/reason/reventless.git#41051a58f655f9bea2d16dd56fce5730069a44f3"
```
For any separate package in the Reventless-Monorepo, which was published via gitpkg it is possible to add a dependency like:
```
    "bs-node-streams": "git+https://gitlab+deploy-token-59148:3FUfgP98A8vvrf26tFDU@gitlab.com/atos-austria/reason/reventless.git#bs-node-streams-v0.0.1-gitpkg"
```

### Modifying Already Published Package
If you really need to change a published package withoug raising the version number, you can delete a remote tag by calling `git push --delete origin TAG-NAME`. Afterwards you can just run gitpkg again. Make sure to fetch this package in it's dependents (without using a cached version).

