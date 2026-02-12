import React from 'react';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';

export default function VersionBanner() {
  const { siteConfig } = useDocusaurusContext();
  const baseUrl = siteConfig.baseUrl;

  // Determine current version based on baseUrl
  let version = null;
  let message = '';
  let backgroundColor = '';
  let color = 'white';

  if (baseUrl.includes('/beta/')) {
    version = 'Beta';
    message = 'You are viewing the BETA documentation. This version is stable but not yet released to production.';
    backgroundColor = '#f4b400';
  } else if (baseUrl.includes('/alpha/')) {
    version = 'Alpha';
    message = 'You are viewing the ALPHA documentation. This is an experimental version and may contain breaking changes.';
    backgroundColor = '#db4437';
  }

  // Don't show banner for stable/latest version
  if (!version) {
    return null;
  }

  return (
    <div style={{
      backgroundColor,
      color,
      padding: '12px 20px',
      textAlign: 'center',
      fontWeight: 500,
      fontSize: '14px',
      position: 'sticky',
      top: 60,
      zIndex: 100,
      boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
    }}>
      <strong>{version} Version:</strong> {message}
      {' '}
      <a
        href="/reventless-core/"
        style={{
          color: 'white',
          textDecoration: 'underline',
          fontWeight: 600
        }}
      >
        View Latest Stable Docs →
      </a>
    </div>
  );
}
