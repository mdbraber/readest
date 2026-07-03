import { copyFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// `tauri ios init` regenerates the AppIcon.appiconset from src-tauri/icons/ios as
// a legacy multi-size icon set and has no notion of iOS 18 dark-appearance icons,
// so our dark variant is dropped on every init. Re-apply it here afterwards.
//
// actool only honors app-icon appearances in the *single-size* (universal 1024)
// layout — it silently ignores `appearances` on multi-size entries — so this
// rewrites Contents.json to that layout with a light + dark 1024, letting actool
// generate every device size for both appearances. iOS < 18 ignores the dark
// entry; iOS 18+ shows it on the dark home screen. Idempotent.

const scriptDir = dirname(fileURLToPath(import.meta.url));
const appDir = resolve(scriptDir, '..');
const appIconSet = resolve(
  appDir,
  'src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset',
);

const lightIcon = 'AppIcon-512@2x.png'; // opaque 1024, emitted by `tauri ios init`
const darkIcon = 'AppIcon-512@2x-dark.png'; // transparent 1024, tracked under icons/ios
const darkSource = resolve(appDir, 'src-tauri/icons/ios', darkIcon);
const contentsPath = resolve(appIconSet, 'Contents.json');

if (!existsSync(contentsPath) || !existsSync(resolve(appIconSet, lightIcon))) {
  throw new Error(
    `AppIcon.appiconset not found at ${appIconSet}. Run \`pnpm tauri ios init\` first.`,
  );
}
if (!existsSync(darkSource)) {
  throw new Error(`Dark icon source missing: ${darkSource}`);
}

await copyFile(darkSource, resolve(appIconSet, darkIcon));

const universal = (filename, appearances) => ({
  idiom: 'universal',
  platform: 'ios',
  size: '1024x1024',
  filename,
  ...(appearances ? { appearances } : {}),
});

const contents = {
  images: [
    universal(lightIcon),
    universal(darkIcon, [{ appearance: 'luminosity', value: 'dark' }]),
  ],
  info: { version: 1, author: 'xcode' },
};

await writeFile(contentsPath, `${JSON.stringify(contents, null, 2)}\n`);

console.log(`Patched ${contentsPath}: single-size app icon with light + dark 1024.`);
