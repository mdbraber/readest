import { describe, it, expect } from 'vitest';
import { existsSync, readFileSync } from 'fs';
import { resolve } from 'path';

/**
 * Regression guard for the iOS 18 dark-appearance app icon.
 *
 * The default (light) app icon is an open book on a solid white background,
 * which glares against the dark home screen. `AppIcon-512@2x-dark.png` is a
 * transparent-background variant that the system composites onto its own dark
 * backdrop instead.
 *
 * `tauri ios init` regenerates `AppIcon.appiconset` as a legacy multi-size icon
 * set and has no notion of dark-appearance icons, so it drops the dark variant
 * on every init. `scripts/patch-ios-dark-icon.mjs` re-applies it (run via
 * `pnpm patch-ios-dark-icon`) by rewriting Contents.json to the single-size
 * layout — the only format actool honors app-icon appearances in.
 *
 * The generated `gen/apple` tree is git-ignored, so the only durable artifacts
 * are the tracked dark source PNG and the patch script; both are asserted here.
 */

const appRoot = process.cwd();
const darkIcon = resolve(appRoot, 'src-tauri/icons/ios/AppIcon-512@2x-dark.png');
const patchScript = resolve(appRoot, 'scripts/patch-ios-dark-icon.mjs');

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

describe('iOS dark app icon', () => {
  it('ships a tracked 1024×1024 dark icon with an alpha channel', () => {
    expect(existsSync(darkIcon), `missing ${darkIcon}`).toBe(true);

    const png = readFileSync(darkIcon);
    expect(png.subarray(0, 8).equals(PNG_SIGNATURE)).toBe(true);

    // IHDR data begins at byte 16: width(4), height(4), bitDepth(1), colorType(1).
    const width = png.readUInt32BE(16);
    const height = png.readUInt32BE(20);
    const colorType = png.readUInt8(25);

    expect(width).toBe(1024);
    expect(height).toBe(1024);
    // Color types 4 (gray+alpha) and 6 (truecolor+alpha) carry an alpha channel;
    // without one the "dark" icon would render its background opaque.
    expect([4, 6]).toContain(colorType);
  });

  it('is wired into the dark-icon patch script', () => {
    expect(existsSync(patchScript)).toBe(true);
    const src = readFileSync(patchScript, 'utf8');
    expect(src).toContain('AppIcon-512@2x-dark.png');
    expect(src).toMatch(/appearance:\s*'luminosity',\s*value:\s*'dark'/);
  });
});
