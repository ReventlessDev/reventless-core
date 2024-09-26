# `aws-lambda-layer`

This package is split into two parts:

- [`lib`](#lib): provides `build` function (and other supportive functions) to build a lambda layer of a node package (with all it's dependencies) into a zip file based on the given parameters
- [`builder`](#builder): reventless specific configuration of the lib to actually build the layer

## Lib

The usual entrypoint of the lib is `require(lib/index.js).build()`.

The `build` function takes an object as it's single argument. For example:

```js
import {resolve as resolvePath, dirname} from 'node:path';
import {fileURLToPath} from 'node:url'
import {build as buildLayer} from '../lib/index.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

const buildOptions = {
    sourcePackageName: '@reventless/reventless-aws',
    sourcePackageVersion: '1.4.14',
    pathToLayerData: resolvePath(__dirname, 'layer/'),
    pathToSavedDependencies: resolvePath(__dirname, 'layer/nodejs/node_modules'),
    excludeScopes: ['pulumi', 'types', 'opentelemetry'],
    excludeModules: ['aws-sdk'],
    postProcess: {
        "@scope/packageName": postProcessFunction, // post process defined package
        ">@scope/packageName": postProcessFunction, // post process any package, which has `@scope/packageName` as a dependency
    }
};

buildLayer(buildOptions);
```

Fields:

- `sourcePackageName`: the name of the package to build the layer for
- `sourcePackageVersion`: the version of the package to build the layer for
- `pathToLayerData`: the root path of data which is to be zipped as the layer
- `pathToSavedDependencies`: the path, where dependencies shall be saved
- `excludeScopes`: array of scopes to be excluded (note: `@scope/name`)
- `excludeModules`: array of modules to be excluded
- `postProcess`: object with the key being a package name, and the value being a post process function to be applied for the given package.
    - post process function signature: `(Arborist.node, cwd) => promise<unit>`
    - the package name in the key may be prepended with `>`, which means: "apply this function to any dependency, which depends on this package"

## Builder

The `builder` directory holds an application, to create a lambda layer for the `reventless-aws` package and all it's dependencies.

If necessary, update the target version of `reventless-aws` in the `index.js` file and run the node application afterwards:

### Precompile JS Artifacts

Some rescript based packages don't ship compiled js files. (e.g. decco or bs-moment). Currently the lib has no `preProcess` functions implemented.

Therefore, these packages need to get compiled and the js files copied into the `builder/precompiled` folder manually.

```
npm run build
```

The application will create/update a zip file called `reventless-layer.zip` inside the `builder` directory.

## Create create a (new) Lambda layer on AWS

### Via the AWS Console

- go to the AWS Lambda section, and select `Layer`
- create a new or update an existing layer by uploading the created zip file

### Via AWS CLI

```
aws publish-layer-version --layer-name reventless-aws --description "reventless-aws@1.4.15" --zip-file fileb://builder/reventless-layer.zip --compatible-runtimes "nodejs16.x" --compatible-architectures "x86_64" --region "eu-west-1"
```
