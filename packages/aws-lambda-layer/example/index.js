import { join as joinPath } from 'node:path';
import { build as buildLayer } from '../lib/index.js';
const pathToLayerData = './layer/';
const pathToSavedDependencies = 'nodejs/node_modules';
const dependenciesPath = joinPath(pathToLayerData, pathToSavedDependencies);
const precompiledPath = './precompiled'

const opt = {
    //pathToSourcePackage: '../reventless-aws',
    sourcePackageName: '@reventless/reventless-aws',
    sourcePackageVersion: '1.3.0-rescript.72',
    pathToLayerData,
    pathToSavedDependencies,
    excludeScopes: ['pulumi', 'types', 'opentelemetry'],
    excludeModules: ['aws-sdk'],
    postProcess: {
        "decco": [
            //"npx rescript@10.1.4 build",
            //"rm -r ppx*"
            "pwd",
            //`cp -r ${joinPath(precompiledPath, '/decco')} ${joinPath(dependenciesPath, '/decco')}`,
            "echo 'do something'",
            // {cmd: 'echo', args: ['do something']},
            // {cmd: 'pwd', args: []},
            // {cmd:'echo', args:['do something else']}
        ],
        ">rescript": [
            "rm -r lib",
            "rm -r **/*.res",
            "rm -r **/*.resi"
        ],
        // TODO: moment
    }
};

buildLayer(opt);