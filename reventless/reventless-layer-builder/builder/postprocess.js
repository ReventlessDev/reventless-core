import {resolve as resolvePath} from 'node:path';
import {rimraf} from 'rimraf';

export async function rescriptDependent(node, cwd) {
    const rmRes = rimraf('**/*.res', {glob: {cwd}});
    const rmResi = rimraf('**/*.resi', {glob: {cwd}});
    return Promise.all([rmRes, rmResi]);
}

export async function reventlessCore(node, cwd) {
    return rimraf([
        resolvePath(cwd, 'coverage'),
        resolvePath(cwd, 'scripts'),
        resolvePath(cwd, 'test-helper'),
        resolvePath(cwd, 'tests')
    ]);
}

export async function deleteTests(node, cwd) {
    return rimraf(resolvePath(cwd, 'tests'));
}

export async function deleteEffectSrc(node, cwd) {
    return rimraf(resolvePath(cwd, 'src'));
}
