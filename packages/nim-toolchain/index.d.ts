/** The exact upstream Nim version installed by this package. */
export const nimVersion: string;

/** A verified Nim distribution and environment for running its tools. */
export interface Toolchain {
  version: string;
  directory: string;
  binDirectory: string;
  nim: string;
  nimble: string;
  nimsuggest: string;
  env: Record<string, string | undefined>;
}

/**
 * Download and verify the pinned Nim distribution if it is not cached.
 * Throws for unsupported platforms or cache paths, failed downloads, or checksum mismatches.
 * The default cache is user-owned; NIM_TOOLCHAIN_CACHE overrides its location.
 * The cache path must not contain spaces or shell metacharacters (a Nimble limitation).
 */
export function getToolchain(options?: { cacheDir?: string }): Promise<Toolchain>;
