import React from 'react';
import VersionBanner from '../components/VersionBanner';

// Root component wrapper to add version banner globally
export default function Root({children}) {
  return (
    <>
      <VersionBanner />
      {children}
    </>
  );
}
