Bundled Dark Reader API 4.9.135 (MIT).

Source: https://registry.npmjs.org/darkreader/-/darkreader-4.9.135.tgz
Project: https://github.com/darkreader/darkreader

`darkreader.js` is the unmodified upstream API build. `LICENSE` accompanies it
in the app bundle. BrowserWorkspace injects it into WebKit's isolated client
world at document start for each frame and enables `auto()` to follow the
effective color scheme. The engine adjusts page styles and watches dynamic
content; returning to light appearance removes its generated styles.
