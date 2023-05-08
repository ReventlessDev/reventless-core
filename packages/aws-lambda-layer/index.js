const { sourcePackageName, sourcePackageVersion, pathToLayerData, pathToSavedDependencies } = require('./config.js');
const Arborist = require('@npmcli/arborist');
const pacote = require('pacote');
const { depth } = require('treeverse');
const fs = require('fs');
const path = require('path');
const http = require('http');

function maxDepth(node, currentDepth = 1) {
    if (node.children && node.children.size > 0) {
        var localMax = 0;
        for (const [key, child] of node.children) {
            if (child === undefined) {
                if (process.env.REVENTLESS_DEBUG)
                    console.log(`child(${key}) is undefined`, child);
                continue;
            };
            if (process.env.REVENTLESS_DEBUG)
                console.log(node.name + " > " + child.name);
            const childMaxDepth = maxDepth(child, currentDepth + 1)
            if (childMaxDepth > localMax) {
                localMax = childMaxDepth;
            }
        }
        if (process.env.REVENTLESS_DEBUG)
            console.log("-----", node.name, "localMax=", localMax);
        return localMax
    } else {
        if (process.env.REVENTLESS_DEBUG)
            console.log("-----", node.name, `> leave(${currentDepth})`);
        return currentDepth;
    }
};

function countChildrenRecursive(node, count = 0) {
    if (!node.children || node.children.size == 0) {
        return 0;
    } else {
        var count = node.children.size;
        node.children.forEach((child, key, map) => {
            count += countChildrenRecursive(child)
        });
        return count;
    }
};

function hasChildren(node) {
    return node.children && node.children.size > 0
}

/*filter the current node and all it's children, based on a predicate function
 * if the predicate returns true, the node will be deleted
 */
function filterNodes(node, predicate = node => false/*keep all nodes*/) {
    var count = 0;
    node.children.forEach((child, key, map) => {
        if (predicate(child) && map.delete(key)) {
            count += 1 + countChildrenRecursive(child);

        } else if (hasChildren(child)) {
            count += filterNodes(child, predicate);
        }
    });
    return count;
}

function predIsDev(node) {
    return node.dev;
};

function predIsDevOpt(node) {
    return node.devOptional;
};

function predIsDevOrDevOpt(node) {
    return predIsDev(node) || predIsDevOpt(node);
}

function predIsNecessary(node) {
    return !(node.dev || node.optional || node.devOptional)
}

function isRescriptModule(node) {
    const test = fs.existsSync(node.path + "/bsconfig.json") || fs.existsSync(node.path + "/rescript.json")
    /*
    if (!test)
        console.log('isRescriptModule?', node);
        */
    return test;
};

function hasRescriptDependency(node) {
    for (const edge of node.edgesOut) {
        if (edge.name === 'rescript' && edge.type === 'prod') {
            return true;
        } else {
            //Uconsole.log(`hasRescriptDependency(${node.name})`, edge);
        };
    }
    return false
};

function flattenChildren(root, children) {
    const rootChildren = root.children;
    children.forEach((node, key, map) => {
        if (map.delete(key) && root.children.set(key, node))
            console.log("moved to root children:", key);
        if (hasChildren(node)) {
            flatten(root, node);
        }
    });
};

function flatten(root) {
    root.children.forEach((node, key, map) => {
        if (hasChildren(node))
            flattenChildren(root, node.children)
    });
};

function stats(node, shouldPrint) {
    const allNodesCount = countChildrenRecursive(node);
    const childNodesCount = node.children.size;
    const stats = {
        allNodesCount: allNodesCount,
        childNodesCount: childNodesCount,
        diffCount: allNodesCount - childNodesCount,
        maxDepth: maxDepth(node)
    };

    if (shouldPrint) {
        console.log("");
        console.log("---------");
        console.log("--STATS--");
        console.log("--" + node.name);
        console.log("---------");

        console.log("total nodes:", stats.allNodesCount)
        console.log("children:", stats.childNodesCount);
        console.log("nested nodes:", stats.diffCount);
        console.log("maxDepth:", stats.maxDepth);
        console.log("------");
        console.log("");
    };
    return stats;
}



const opts = {
    //path: "./",
    //path: "../../../fidap/wm-raw/plugin",
    //"@fidap-wm-raw:registry": "https://gitlab.com/api/v4/projects/43406890/packages/npm/",
    "@fidap-wm-raw:registry": "https://gitlab.com/api/v4/packages/npm/",
    "@fidap:registry": "https://gitlab.com/api/v4/packages/npm/",
    "@reventless:registry": "https://gitlab.com/api/v4/packages/npm/",
    "//gitlab.com/api/v4/projects/40879371/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
    "//gitlab.com/api/v4/projects/43406890/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
    "//gitlab.com/api/v4/projects/24127696/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
    "//gitlab.com/api/v4/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN
}

const modulePath = path.join(__dirname, pathToLayerData, pathToSavedDependencies)
const rootPath = path.join(modulePath, sourcePackageName)
const sourcePackageVersionStr = (sourcePackageVersion) ? sourcePackageVersion : 'latest';
const sourcePackageSpec = `${sourcePackageName}@${sourcePackageVersionStr}`
console.log('root module:', sourcePackageSpec);
console.log('storing modules in:', modulePath);
console.log('storing root module in:', rootPath);

var rescriptModule = undefined;
var rescriptStdModule = undefined;
var extractionCount = 0;
var skippedExtractionCount = 0;

return pacote.extract(sourcePackageSpec,
    rootPath,
    opts)
    .then(res => {
        console.log('extract result:', res);

        const arb = new Arborist({
            ...opts,
            path: rootPath
        });


        return arb.buildIdealTree({
            update: true,
            preferDedupe: true,
        })
    })
    .then(tree => {
        stats(tree, true);

        console.log();
        //console.log("filtered nodes", filterNodes(tree, predIsDevOrDevOpt));
        console.log("total nodes in tree=", countChildrenRecursive(tree))

        //stats(tree, true);

        /*
        tree.children.forEach(ch => {
            console.log(ch.name, ch.dev, ch.devOptional, ch.optional, ch.peer)
        });
        */

        console.log("");
        /*
        tree.children.forEach((ch, key, map) => {
            if (isRescriptModule(ch.path))
                rescriptModules.push(ch)
        });
        */

        return depth({
            tree: tree,
            visit: node => {
                if (node.isRoot) {
                    console.log(`skip extracting ${node.name}@${node.version}`);
                    return;
                } else if (node.name === 'rescript') {
                    console.log(`found ${node.name}@${node.version}`);
                    rescriptModule = node;
                } else if (node.name === '@rescript/std') {
                    console.log(`found ${node.name}@${node.version}`);
                    rescriptStdModule = node;
                };
                if (!predIsNecessary(node)) {
                    const extractOpts = { ...opts, resolved: node.resolved };
                    return pacote.extract(node.name + '@' + node.version,
                        path.join(modulePath, node.name),
                        extractOpts)
                        .then(res => {
                            extractionCount += 1;
                        });
                } else {
                    skippedExtractionCount += 1;
                    console.log(`skipping extraction of ${node.name} because it's a dev / optional dev / optional dependency`);
                };
            },
            getChildren: node => hasChildren(node) ? Array.from(node.children.values()) : [],
        });
    })
    .then(res => {
        console.log('depth done:', res);
        console.log("RESCRIPT MODULE:", rescriptModule);
        console.log("RESCRIPT STD MODULE:", rescriptStdModule);
        console.log("SKIPPED EXTRACTIONS:", skippedExtractionCount);
        console.log("EXTRACTIONS:", extractionCount);
    });

    // TODO: build all rescript dependencies to ensure up-to-date and existing js artifacts
        // maybe only build packages defined in config?
        // maybe install rescript somewhere above pathToLayerData, so it won't get zipped but can be executed to build
        // maybe use rescript version defined in sourcePackage (dev-/peer-) deps or from config?
    // TODO: remove / replace all references/usage of `rescript` package --> use @rescript/std instead
    // TODO: remove all res(i), bsconfig, lib files
    // TODO: zip everything in `pathToLayerData` directory