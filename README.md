# dsh-mac

A native macOS window for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness). It runs the real DSH web UI in its own app, so your coding agent does not share a browser profile, session, or keyboard-shortcut namespace with your personal browsing.

The app starts `dsh web`, waits for it to listen, shows the GUI in a `WKWebView`, and stops the server when you quit.

## What this is

One Swift file. It is a shell, not a fork: it implements no harness logic, reimplements no UI, and reads no DSH config, API, or plugin interface. Everything in the window is upstream DSH.

It is not a chat client. It does not call any model API, store conversations, or manage credentials. It launches a harness and displays it.

## Requirements

- macOS 13 or later
- The Xcode Command Line Tools (`xcode-select --install`)
- Node and npm, to fetch the harness

You do **not** need DSH installed beforehand. If you have it, the first launch uses your copy immediately; if you do not, the app fetches one.

## Install

```sh
git clone https://github.com/barisuraz/dsh-mac
cd dsh-mac
./build.sh
open "build/DeepSeek Harness.app"
```

`build.sh` downloads nothing. To keep it in your Applications folder:

```sh
cp -R "build/DeepSeek Harness.app" /Applications/
```

The app is ad-hoc signed rather than notarized, so a downloaded copy is quarantined by macOS. Either build it yourself as above, or clear the flag once:

```sh
xattr -dr com.apple.quarantine "/Applications/DeepSeek Harness.app"
```

Maintainers can produce a notarized build that needs no such workaround; see [Releasing](#releasing).

## Updates

DSH is in developer preview and changes constantly, so the app updates it for you on every launch. It does that the way Android does A/B system updates: two copies are kept, an update only ever lands in the idle one, and the running copy is never modified.

```
        ┌───────────────┐         ┌───────────────┐
        │    slot a     │         │    slot b     │
        │  running now  │         │   fallback    │
        └───────────────┘         └───────────────┘
                 ▲                        ▲
     boots from here            new version is
     and keeps working          installed here
```

On launch:

1. The app boots the preferred slot and shows your GUI. This does not wait for any download.
2. Once the running version has stayed up for a minute, the newest release is installed into the other slot.
3. That copy is started on a throwaway port and must serve the UI before it is trusted. Only then is it marked ready.
4. On the next launch it becomes the running version, and the version it replaced stays as the fallback.

If the new version turns out to be bad, the app recovers on its own and tells you:

- **It will not start.** The startup check catches it before it ever becomes your running version, and it is discarded.
- **It starts and then keeps dying.** A version that served and then stopped within a minute is counted as an early exit. Three of those and the app stops retrying, marks that version broken, and switches back to the other slot.

Either way you get a banner naming the version that failed, the version you are now running, and why. Nothing is deleted behind your back: the slot that failed is kept and marked, and a version that failed to start is not downloaded again. `Check for Harness Updates` (`⌘U`) clears that verdict and retries; `Reinstall Harness…` rebuilds the idle slot from scratch.

Two copies of the harness take roughly 600 MB, plus an npm cache the app keeps to itself in `~/Library/Application Support/DeepSeekHarness`. Your own npm cache is never touched.

### First run

You never have to install DSH yourself. If no harness exists on the machine, the first launch installs one into a slot and serves it. If you already have one, the app uses that copy immediately — the first launch is as fast as you are used to — and provisions a managed slot in the background for the next one. Either way, your existing setup is left exactly as it was.

## Behaviour worth knowing

**Your existing harness is left alone.** If port `3080` is already taken, the app asks the OS for a free port instead of fighting over it.

**Nothing outlives the app.** The server runs under a small supervisor that shuts it down even if the app is force-killed, so you will not find an orphaned `node` process holding a port.

**Its storage is its own.** The webview uses the app's own container, so cookies and local storage never mix with Chrome, Safari, or any other browser profile.

**Your sessions carry over.** The app uses the same `~/.dsh` as the command line, so existing sessions, workspaces, and credentials appear with no migration.

**It fails visibly.** If the harness cannot start, the window shows the reason and the last lines of the harness's own output rather than a blank page. The same text goes to `~/Library/Logs/DeepSeekHarness/wrapper.log`.

## Configuration

All optional, read from the environment, so launch from a terminal to use them.

| Variable | Default | Meaning |
| --- | --- | --- |
| `DSH_WRAPPER_PORT` | `3080` | Port to prefer; falls back to an OS-assigned port if busy. |
| `DSH_MANAGED` | `1` | Set to `0` to skip slots and updates entirely and use whatever `dsh` resolves to. |
| `DSH_NO_AUTO_UPDATE` | `0` | Set to `1` to keep slots but never fetch anything on launch. |
| `DSH_NO_SYSTEM_DSH` | `0` | Set to `1` to ignore any harness on `PATH` and use only managed slots. |
| `DSH_SLOT_VERSION` | newest | Pin slots to a specific version instead of tracking the newest. |
| `DSH_BIN` | auto-detected | Explicit path to a `dsh` executable. |
| `DSH_NPM_BIN` | auto-detected | Explicit path to `npm`. |
| `DSH_APP_SUPPORT` | `~/Library/Application Support/DeepSeekHarness` | Where slots and update state live. |
| `DSH_WRAPPER_LOG` | `~/Library/Logs/DeepSeekHarness/wrapper.log` | Where to write diagnostics. |

`DSH_HOME` and the rest of your DSH environment are inherited unchanged.

## Keyboard

| Shortcut | Action |
| --- | --- |
| `⌘R` | Reload the GUI |
| `⇧⌘R` | Restart the harness |
| `⌘U` | Check for Harness updates |
| `⌘+` / `⌘-` / `⌘0` | Zoom |
| `⌘Q` | Quit and stop the harness |

## Maintenance

The real risk with any wrapper is that upstream moves and the wrapper rots. This one keeps its coupling to a single contract:

> 1. a `dsh` executable can be resolved,
> 2. `dsh web --no-open --port N` serves the GUI on loopback,
> 3. it prints a loopback URL carrying a `token` parameter.

That is all of it. Keeping the coupling at the process boundary is deliberate; it is the most stable seam DSH offers, and it is why a shell needs less upkeep than a plugin or a fork.

Claim 3 is a log line rather than a documented interface, so it is the part most likely to change. Two things guard it:

- The parser accepts a reworded line, needing only *some* loopback URL carrying a token, not an exact prefix.
- `--test-parser` and `--check-contract` fail loudly when upstream drifts. CI runs both on every push and weekly.

If upstream changes something, you get a red build naming the claim that broke instead of a window that never loads.

Because the window renders upstream's own frontend, new harness features appear in the app as soon as they ship. The app has nothing to reimplement and therefore nothing to fall behind on.

### Diagnostics

```sh
APP="build/DeepSeek Harness.app/Contents/MacOS/DeepSeekHarness"

# what the app resolved, without opening a window
"$APP" --selftest

# the readiness-line parser, including the cases it must refuse
"$APP" --test-parser

# A/B slot bookkeeping and crash-loop detection
"$APP" --test-update

# fetch and verify a harness into a slot, without opening a window
"$APP" --install-harness

# starts a real harness and verifies the full contract
"$APP" --check-contract

# end-to-end recovery: drives the app against deliberately broken harnesses
./tools/test-ab.sh
```

## Security notes

The harness server runs local code execution behind a loopback URL. The app respects that boundary:

- Only `http` URLs on `127.0.0.1` or `localhost` carrying a `token` parameter are ever loaded. The parser is tested against non-loopback and non-http input.
- The token is read from the harness's own output and used once to load the GUI. It is redacted from all diagnostic output.
- DSH refuses to bind `0.0.0.0`, and this app does not change that.
- Links to other sites open in your default browser rather than inside the harness window.
- Installs run `npm install` with the app's own cache directory. Nothing is installed globally and no shell profile is modified.
- DSH is in developer preview. Review anything you run against your own machine.

## Project layout

```
Sources/main.swift          the entire app: window, launcher, supervisor, slots, diagnostics
tools/make-icon.swift       the icon, drawn as vectors at each required size
tools/deepseek-whale.path   the whale outline, taken from DSH's own frontend asset
tools/test-ab.sh            end-to-end update and recovery tests
tools/notarize.sh           sign, notarize, and staple a release build
build.sh                    compiles, assembles, icons, and signs the bundle
Info.plist                  bundle metadata
.github/workflows/ci.yml    build, contract check, and both test suites
```

## Releasing

Builds are ad-hoc signed by default, which is all a locally built copy needs. For a release other people can open without a Gatekeeper warning, the app has to be signed with a **Developer ID Application** certificate and notarized by Apple. That requires a paid Apple Developer account; there is no way around it.

`build.sh` always enables the hardened runtime, so what you test locally is what gets notarized. Set `DSH_SIGN_IDENTITY` to sign for distribution:

```sh
xcrun notarytool store-credentials "dsh-mac" \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "app-specific-password"

DSH_SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
  ./tools/notarize.sh --check     # verify prerequisites first

DSH_SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
  ./tools/notarize.sh             # build, submit, staple
```

The script builds and signs the app, refuses to continue if the signature is not Developer ID, not hardened, or not timestamped, submits the bundle with `notarytool --wait`, staples the ticket, checks that Gatekeeper accepts the result, and leaves a `build/dsh-mac-<version>.zip` ready to upload. The step-by-step setup for the certificate and the app-specific password is in the header of [tools/notarize.sh](tools/notarize.sh).

The app needs no entitlement exceptions: it is a plain AppKit app that spawns `node` and `zsh` as separate processes, and hardened runtime restrictions are per-binary, so the interpreter it launches is unaffected. `build.sh` will pick up a `tools/entitlements.plist` if one is ever needed.

## License

MIT, see [LICENSE](LICENSE).

The app icon uses the DeepSeek whale mark, parsed from the same vector asset DSH ships in its web frontend. The mark belongs to DeepSeek and is used here only to identify what the app runs. Replace it if you redistribute this under a different name. This project is not affiliated with or endorsed by DeepSeek.
