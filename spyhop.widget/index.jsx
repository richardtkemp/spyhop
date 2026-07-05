// spyhop — Übersicht widget wrapper
// Renders the spyhop living-ocean page as a full-screen desktop wallpaper.
//
// Install (on your Mac):
//   1. brew install --cask ubersicht   (then launch it)
//   2. Copy this whole `spyhop.widget` folder into:
//        ~/Library/Application Support/Übersicht/widgets/
//   3. Übersicht menu-bar icon → Refresh All.
//   (Your Mac and the spyhop host must be on the same LAN.)

// Render settings (fps cap, dpr, wiggle) now come from the server config's
// `render` block — see ~/.config/spyhop/config.json. URL query params still override.
const URL = "http://your-host:8477/?bench=1&spritePhases=16&debug=1";

export const refreshFrequency = false;

export const className = `
  position: fixed !important;
  top: 0 !important;
  left: 0 !important;
  width: 100vw !important;
  height: 100vh !important;
  margin: 0;
  padding: 0;
  overflow: hidden;
  z-index: -1;
  pointer-events: none;
  background: #05070f;

  & iframe {
    display: block;
    width: 100%;
    height: 100%;
    border: 0;
  }
`;

// Übersicht paints this widget on EVERY display; render on just one (the primary,
// menu-bar screen, availLeft 0) so the second animation loop doesn't run.
// To target the other screen instead, change `=== 0` to `!== 0`.
export const render = () =>
  window.screen.availLeft === 0
    ? <iframe src={URL} scrolling="no" />
    : <div />;
