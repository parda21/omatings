# omatings — developer guide

Omarchy Settings: a GNOME-style settings app that runs as a `panel` plugin
inside `omarchy-shell` (Quickshell 0.3 / Qt 6 / QML). It manages the OS
without the user having to open config files.

## Layout

```
manifest.json         plugin manifest (id "omatings", kind "panel")
Settings.qml          host: window, sidebar, search, page loader, toast, confirm
Core/Sys.qml          system access (run, sh, json, readFile, writeFile, hyprReload, hyprEval, updateShellConfig, terminal)
Core/ManagedBlock.js  owned regions inside user config files + Lua literal helpers
Core/Pages.js         sidebar registry (id, title, icon, source, keywords)
Core/SettingsSection.qml, Core/SettingsRow.qml   shared layout
pages/<Name>Page.qml  one file per sidebar entry
pages/<area>/...      page-private components/JS (create freely)
tools/check.sh        headless load check (never touches the live shell)
tools/harness.qml     the harness check.sh runs (copied into a temp Quickshell root)
tools/tests/          pure-logic and write-path tests (run with check.sh)
scripts/install.sh    dev install: symlink into ~/.config/omarchy/plugins + enable
docs/media/           README screenshots and GIFs
```

Open it: `omarchy-shell shell toggle omatings '{"page":"displays"}'`

## Page contract

A page is a `ColumnLayout` (copy `pages/_Template.qml`):

- `property var sys` / `property var app` are injected after load.
- `function activated()` runs whenever the page becomes visible — (re)load live state here. It also runs right after `sys` is injected, so `sys` is always set inside it. Guard other uses with `if (!sys) return`.
- Height comes from `implicitHeight`; width is set by the host. Don't add your own outer Flickable.
- `app.toast(text, isError)`, `app.confirm(message, confirmText, fn)`, `app.openPage(id)`, `app.window` (the FloatingWindow, use as popup parent if needed).

## UI rules (look like Omarchy)

- Use the Omarchy kit from `qs.Ui` — `Button`, `ButtonGroup`, `Toggle` (labelled row with switch), `ToggleSwitch`, `Dropdown`, `SearchableDropdown`, `PanelSlider` (pass `bar: null`), `TextField`, `NumberField`, `PanelSectionHeader`, `PanelSeparator`, `CursorSurface`, `BorderSurface`. Read their sources in `/usr/share/omarchy/shell/Ui/` for the API and `/usr/share/omarchy/shell/plugins/dev-gallery/GalleryPanel.qml` for usage.
- Colors only from `qs.Commons` `Commons.Color.*` (foreground, background, accent, urgent, muted) and `Style.*Fill`/`Util.alpha(...)`. Fonts: `Style.font.family` with `Style.font.*` sizes. Spacing: `Style.spacing.*`. Corners: `Style.cornerRadius`. No hardcoded colors or font families — everything must follow the active theme.
- Icons: Nerd Font glyphs via `String.fromCodePoint(0xF....)`.
- Group settings with `SettingsSection` + `SettingsRow` (see their header comments). Page spacing: `Style.spacing.huge`.
- UI text in English, short, sentence case. Describe consequences in `description`, not in labels.
- Every action gives feedback: success toast for writes, error toast with stderr on failure, a busy state for slow commands.

## System rules

- Prefer `omarchy …` commands (`omarchy commands`, `omarchy <group> --help`, source via `cat $(which omarchy-…)`) over reimplementing logic. Reading `/usr/share/omarchy/` is encouraged; **never edit it**.
- Hyprland config is Lua in `~/.config/hypr/*.lua`. Persist changes in a managed block (`Core/ManagedBlock.js`, comment `"--"`) in the matching file — never rewrite the user's own lines. After writing, call `sys.hyprReload(cb)` and toast any errors it returns. Live, non-persisted changes: `sys.hyprEval(lua)`.
- `~/.config/omarchy/shell.json`: use `sys.updateShellConfig(mutate, cb)`; the shell hot-reloads it.
- `sys.writeFile` backs up once per session and writes atomically. Never write anywhere else without it.
- Interactive/privileged things (sudo, TUIs, long updates): open them in a terminal via `sys.terminal("cmd")`. Never call `sudo` from QML directly; `pkexec` only for one-shot commands without a terminal.
- Pass user values as `sys.sh(script, [args])` arguments, never string-interpolate them into scripts.

## Development rules (important — this runs on a real machine)

- Validate with `tools/check.sh pages/YourPage.qml` (and any page-private QML). It must print `-> ok`. Slow tests may need `OMATINGS_CHECK_WAIT=<ms>` (each file is capped at 20 s). It loads the file headlessly with a real `sys`; `activated()` runs, so read-only commands execute for real.
- **Read-only commands are fine** (`hyprctl … -j`, `wpctl status`, `nmcli … list`, `omarchy … list|current|--help`, reading configs).
- **Do not change live system state while developing**: no applying monitor/audio/network/bluetooth/theme/font/power changes, no writes into `~/.config`, no package installs, no sudo/pkexec, no updates/reboots, no `omarchy-shell` summon/restart/rescan. Write paths should be testable against a temp file: give pages a `property string configPath` (defaulting to the real path) so a test can point it at `/tmp/omatings-<area>/`.
- Don't make write actions run from `activated()` or on load — only from explicit user actions.
- Don't edit `Settings.qml`, `Core/*`, `Pages.js` or other agents' pages. If you need a Core change, describe it in your report instead.
- No git commits.
