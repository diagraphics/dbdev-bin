#!/usr/bin/env node

import { existsSync, symlinkSync, renameSync, unlinkSync } from 'fs';
import { platform, arch } from 'process';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

const binaryName = `dbdev-${platform}-${arch}`;
const binaryPath = join(__dirname, 'bin', binaryName);
const symlinkPath = join(__dirname, 'bin', 'dbdev');
const tempSymlinkPath = join(__dirname, 'bin', `.dbdev.tmp.${process.pid}`);

if (!existsSync(binaryPath)) {
  console.error(`Error: No binary found for platform=${platform} arch=${arch}`);
  console.error(`Expected binary at: ${binaryPath}`);
  process.exit(1);
}

try {
  // Create temporary symlink
  symlinkSync(binaryName, tempSymlinkPath);

  // Atomically replace the target symlink
  renameSync(tempSymlinkPath, symlinkPath);

  console.log(`Linked ${binaryName} -> bin/dbdev`);
} catch (err) {
  // Clean up temp symlink if it exists
  if (existsSync(tempSymlinkPath)) {
    unlinkSync(tempSymlinkPath);
  }
  throw err;
}
