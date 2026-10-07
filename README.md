# MacMonMenu

MacMonMenu is a macOS menu bar app that runs [macmon](https://github.com/vladkens/macmon) in a small terminal. Click the CPU icon in the menu bar to open the monitor. Click outside the panel to close it. The app has no Dock icon.

macmon itself is not bundled. MacMonMenu launches the Homebrew binary at `/opt/homebrew/bin/macmon` or `/usr/local/bin/macmon`.

## Requirements

- macOS 26.4 or later
- [Homebrew](https://brew.sh)
- macmon: `brew install macmon`
- Xcode 26 or later, to build the app

## Use

1. Launch MacMonMenu. A CPU icon appears in the menu bar.
2. Click the icon. A panel opens and starts `macmon`.
3. Click outside the panel to dismiss it. The `macmon` process is stopped when the panel closes.
4. Click the icon again for a fresh session.

On each launch, the app asks Homebrew whether a newer `macmon` formula is available. Homebrew refreshes its formula index on its own schedule, the same way a normal `brew` command does. If an update exists, MacMonMenu asks before doing anything:

- **Update** runs `brew upgrade --formula macmon` in the background. Only that formula is upgraded. When it finishes, a notification says the new version will be used the next time you open the panel. If notifications are disabled, the same message is shown as an alert. A failed upgrade is always an alert.
- **Not Now** leaves the installed version in place. The question is asked again the next time the app starts, as long as macmon is still outdated.

A pinned formula is left alone. If Homebrew or macmon is missing, the app still launches and simply does not offer an update.

## Build

Open `MacMonMenu.xcodeproj` and run the **MacMonMenu** scheme, or build from the command line:

```sh
xcodebuild -project MacMonMenu.xcodeproj -scheme MacMonMenu -destination 'platform=macOS' build
```

The built app is written to Xcode’s DerivedData folder. Copy `MacMonMenu.app` to `/Applications` if you want it available as a normal application.

The project depends on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), which Xcode fetches with Swift Package Manager.
