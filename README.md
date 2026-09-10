# dsh-mac

A native macOS window for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — the real DSH web UI, in its own app, with no browser involved.

The app starts `dsh web` for you, waits for it to listen, shows the GUI in a `WKWebView`, and stops the server when you quit.

```
┌──────────────────────────────┐
│ ● ● ●      DeepSeek Harness  │
├──────────────────────────────┤
│                              │
│   the real DSH web GUI       │
│   in a native window         │
│                              │
└──────────────────────────────┘
```

## Why this exists

DSH already ships a complete agent runtime and web UI. What it does not ship is a way to run that UI as an app: you start a server in a terminal, then open a browser tab, and now your coding agent shares a profile, a session, and a keyboard-shortcut namespace with your personal browsing.

`dsh-mac` is one Swift file of about 1000 lines that closes that gap. It is a **shell, not a fork**: it implements no harness logic, reimplements no UI, and reads no DSH config, API, or plugin interface. Everything you see in the window is upstream DSH.

## What it is not

It is not a chat client. It does not talk to any model API itself, store your conversations, or manage credentials. It launches the harness you already have and displays it.

## Requirements

- macOS 13 or later
- The Xcode Command Line Tools (`xcode-select --install`)
- DSH installed and working: `npm i -g @deepseek-ai/dsh`

## Install

```sh
git clone https://github.com/barisuraz/dsh-mac
cd dsh-mac
./build.sh
open "build/DeepSeek Harness.app"
```

`build.sh` needs no network access and downloads nothing. To keep it in your Applications folder:

```sh
cp -R "build/DeepSeek Harness.app" /Applications/
```

The app is ad-hoc signed, so the first launch from Finder may ask for confirmation. Built locally by you, that is expected.

## Behaviour worth knowing

**It manages its own server.** Launching the app starts `dsh web --no-open`; quitting stops it. A `dsh` you started yourself is never touched.

**Your existing harness is left alone.** If port `3080` is already taken, the app asks the OS for a free port instead of fighting over it or showing an error.

**Nothing outlives the app.** The server is started under a small supervisor that shuts it down even if the app is force-killed, so you will not find an orphaned `node` process holding a port.

**Its storage is its own.** The webview uses the app's own container, so cookies and local storage never mix with Chrome, Safari, or any other browser profile.

**It fails visibly.** If the harness cannot start, the window shows the reason and the last lines of the harness's own output instead of a blank page. The same text is appended to `~/Library/Logs/DeepSeekHarness/wrapper.log`.

## Configuration

Both are optional and read from the environment, so launch from a terminal to use them:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DSH_WRAPPER_PORT` | `3080` | Port to prefer; falls back to an OS-assigned port if busy. |
| `DSH_BIN` | auto-detected | Explicit path to the `dsh` executable. |
| `DSH_WRAPPER_LOG` | `~/Library/Logs/DeepSeekHarness/wrapper.log` | Where to write diagnostics. |

`DSH_HOME` and the rest of your DSH environment are inherited unchanged.

## Keyboard

| Shortcut | Action |
| --- | --- |
| `⌘R` | Reload the GUI |
| `⇧⌘R` | Restart the harness |
| `⌘+` / `⌘-` / `⌘0` | Zoom |
| `⌘Q` | Quit and stop the harness |

## Maintenance

The honest risk with any wrapper is that upstream moves and the wrapper rots. So this one keeps its coupling to a single, explicitly tested contract:

> 1. a `dsh` executable can be resolved,
> 2. `dsh web --no-open --port N` serves the GUI on loopback,
> 3. it prints a loopback URL carrying a `token` parameter.

That is the whole of it. The app reads no DSH config, API, or plugin interface, which is deliberate: the process boundary is the most stable seam DSH offers, and it is why a native shell needs less upkeep than a plugin or a fork would.

Because claim 3 is a log line rather than a documented interface, it is the part most likely to change. Two things guard it:

- The parser accepts a reworded line, needing only *some* loopback URL carrying a token — not an exact prefix.
- `--test-parser` and `--check-contract` fail loudly when upstream drifts, and CI runs both on every push and weekly.

If upstream changes something, the failure is a red build naming the claim that broke, not a user staring at a window that never loads.

```sh
# what the app resolved, without opening a window
"build/DeepSeek Harness.app/Contents/MacOS/DeepSeekHarness" --selftest

# readiness-line parser, including the cases it must refuse
"build/DeepSeek Harness.app/Contents/MacOS/DeepSeekHarness" --test-parser

# starts a real harness and verifies the full contract
"build/DeepSeek Harness.app/Contents/MacOS/DeepSeekHarness" --check-contract
```

## Security notes

The harness web server runs local code execution behind a loopback URL. This app is built to respect that boundary:

- Only `http` URLs on `127.0.0.1` or `localhost` carrying a `token` parameter are ever loaded. The parser is tested against non-loopback and non-http input.
- The token is read from the harness's own output and used once to load the GUI; it is redacted from all diagnostic output.
- DSH refuses to bind `0.0.0.0`, and this app does not change that.
- Links to other sites open in your default browser rather than inside the harness window.
- DSH is in developer preview. Review anything you run against your own machine.

## Project layout

```
Sources/main.swift          the entire app: window, launcher, supervisor, diagnostics
tools/make-icon.swift       the icon, drawn as vectors at each required size
tools/deepseek-whale.path   the whale outline, taken from DSH's own frontend asset
build.sh                    compiles, assembles, icons, and signs the bundle
Info.plist                  bundle metadata
```

## License

MIT — see [LICENSE](LICENSE).

The app icon uses the DeepSeek whale mark, and the outline is parsed from the same vector asset DSH ships in its own web frontend. The mark belongs to DeepSeek; it is used here only to identify what the app runs. Remove or replace it if you redistribute this under a different name. This project is not affiliated with or endorsed by DeepSeek.

The app icon uses the DeepSeek whale mark, and the outline is parsed from the same vector asset DSH ships in its own web frontend. The mark belongs to DeepSeek; it is used here only to identify what the app runs. Remove or replace it if you redistribute this under a different name. This project is not affiliated with or endorsed by DeepSeek.
