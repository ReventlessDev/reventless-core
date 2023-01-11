export const createFiles = {
  type: 'addMany',
  destination: 'src/Extensions/{{properCase pluginName}}.{{properCase extensionPointName}}/',
  base: 'plop-templates/Extension/',
  templateFiles: 'plop-templates/Extension/**/*'
};
export const addToMain = {
  type: "modify",
  path: "src/Main.re",
  pattern: /(~extensions\W[\S\s]*?\[\|)/,
  template: "$1(module {{properCase extensionPointName}}Extension),",
};
