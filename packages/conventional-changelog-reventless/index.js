const angular = require('conventional-changelog-angular');

function stripCoAuthoredBy(text) {
  if (!text) return text;
  return text.replace(/\n*Co-Authored-By:.*$/gmi, '').trim() || null;
}

module.exports = function(config) {
  return angular(config).then(preset => {
    // Strip Co-Authored-By trailers from changelog entries
    const originalTransform = preset.writerOpts.transform;
    preset.writerOpts.transform = (commit, context) => {
      if (commit.body) commit.body = stripCoAuthoredBy(commit.body);
      if (commit.footer) commit.footer = stripCoAuthoredBy(commit.footer);
      if (commit.notes) {
        commit.notes = commit.notes.map(note => ({
          ...note,
          text: stripCoAuthoredBy(note.text) || note.text
        }));
      }
      if (typeof originalTransform === 'function') {
        return originalTransform(commit, context);
      }
      return commit;
    };

    // Modify the main template to reduce blank lines
    preset.writerOpts.mainTemplate = `{{> header}}

{{#each commitGroups}}
{{#if title}}
### {{title}}

{{/if}}
{{#each commits}}
{{> commit root=@root}}
{{/each}}
{{/each}}
{{> footer}}
`;

    return preset;
  });
};
