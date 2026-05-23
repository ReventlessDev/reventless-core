import useDocusaurusContext from '@docusaurus/useDocusaurusContext';

const versions = [
  { name: 'Latest', path: '/' },
  { name: 'Beta', path: '/beta/' },
  { name: 'Alpha', path: '/alpha/' },
];

// Compact, navbar-native version switcher. Registered as the
// `custom-versionSwitcher` navbar item type (see theme/NavbarItem/ComponentTypes).
export default function VersionSwitcher() {
  const { siteConfig } = useDocusaurusContext();
  const baseUrl = siteConfig.baseUrl;

  let currentVersion = 'Latest';
  if (baseUrl.includes('/beta/')) {
    currentVersion = 'Beta';
  } else if (baseUrl.includes('/alpha/')) {
    currentVersion = 'Alpha';
  }

  return (
    <select
      className="navbar__version-select"
      aria-label="Documentation version"
      value={currentVersion}
      onChange={(e) => {
        const selected = versions.find((v) => v.name === e.target.value);
        if (selected) {
          const basePathRegex = /^\/reventless-core(\/beta|\/alpha)?\//;
          const pathAfterBase = window.location.pathname.replace(basePathRegex, '');
          window.location.href = `${window.location.origin}/reventless-core${selected.path}${pathAfterBase}`;
        }
      }}
    >
      {versions.map((v) => (
        <option key={v.name} value={v.name}>
          {v.name}
        </option>
      ))}
    </select>
  );
}
