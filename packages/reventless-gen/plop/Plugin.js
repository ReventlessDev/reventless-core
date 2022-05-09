export const createPluginFiles = {
  type: 'addMany',
  destination: '{{dashCase pluginName}}/',
  base: 'plop-templates/Plugin/',
  templateFiles: 'plop-templates/Plugin/**/*',
  globOptions: {dot: true}
};
export const gitInitPlugin = (plop, data) => ({
  type: 'gitInit',
  path: `${process.cwd()}/${plop.getHelper("dashCase")(data.pluginName)}/`,
  verbose: true,
  abortOnFail: false
});
export const npmInstallPlugin = (plop, data) => ({
  type: 'npmInstall',
  path: `${process.cwd()}/${plop.getHelper("dashCase")(data.pluginName)}/plugin`,
  verbose: true
});
export const rebuildPlugin = (plop, data) => ({
  type: 'rebuild',
  path: `${process.cwd()}/${plop.getHelper("dashCase")(data.pluginName)}/plugin`,
  verbose: true,
  abortOnFail: false
});
export const npmInstallUi = (plop, data) => ({
  type: 'npmInstall',
  path: `${process.cwd()}/${plop.getHelper("dashCase")(data.pluginName)}/ui`,
  verbose: true
});
export const rebuildUi = (plop, data) => ({
  type: 'rebuild',
  path: `${process.cwd()}/${plop.getHelper("dashCase")(data.pluginName)}/ui`,
  verbose: true,
  abortOnFail: false
});
