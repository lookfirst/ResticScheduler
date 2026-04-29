# Agent Notes

## Project

Restic Scheduler is a native macOS menu bar app. The main app scheme is `Restic Scheduler`; the release app bundle produced by Xcode is named `Restic Scheduler.app`.

## Local Configuration

- `Config.xcconfig` is required for local builds and is intentionally ignored by git.
- Use `Config.example.xcconfig` as the template when recreating it.
- This checkout currently expects:
  - `CODE_SIGN_STYLE = Automatic`
  - `CODE_SIGN_IDENTITY = Apple Development`
  - `DEVELOPMENT_TEAM = [PUT YOUR DEV TEAM ID HERE FROM BEING LOGGED INTO XCODE]`
  - `APP_BUNDLE_ID = ru.makinen.ResticScheduler`
  - `APP_RESTIC_BINARY = /opt/homebrew/bin/restic`
- Do not overwrite `Config.xcconfig` unless the user explicitly asks for configuration changes.

## Build

Use this command for the standard local release build:

```sh
xcodebuild -scheme 'Restic Scheduler' -configuration Release -destination 'platform=macOS' build
```

For concise verification output, pipe through ripgrep:

```sh
xcodebuild -scheme 'Restic Scheduler' -configuration Release -destination 'platform=macOS' build 2>&1 | rg -n -C 3 "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"
```

The expected release build product path in this checkout is:

```sh
~/Library/Developer/Xcode/DerivedData/ResticScheduler-eaveurxprpqrcehbjeqkncthwxqt/Build/Products/Release/Restic Scheduler.app
```

If DerivedData changes, locate the app with Xcode's build output rather than launching an old bundle.

## Install And Restart

When the user asks to build and restart, do not launch directly from DerivedData. Install the freshly built app into `/Applications` first.

Use this sequence:

```sh
osascript -e 'tell application "Restic Scheduler" to quit'
ditto "~/Library/Developer/Xcode/DerivedData/ResticScheduler-eaveurxprpqrcehbjeqkncthwxqt/Build/Products/Release/Restic Scheduler.app" "/Applications/Restic Scheduler.app"
open "/Applications/Restic Scheduler.app"
```

Notes:

- Quit the app before copying so the running menu bar process is not using the bundle being replaced.
- Use `ditto` for the app bundle copy.
- Restart from `/Applications/Restic Scheduler.app`, not the DerivedData app.
- If the app was not running, the quit command may be harmless; continue with copy and open.

## Git Commits

When the user asks to add and commit changes, split the work into individual commits based on the intent of each change. Do not collapse unrelated UI, scheduler, runner, storage, configuration, and documentation changes into one commit just because they were made in the same session.

Use conventional commit messages:

```text
type(scope): summary
```

Examples:

```text
fix(runner): parse permission errors from stderr
feat(storage): cache repository stats between launches
docs(agents): document release install workflow
```

Guidelines:

- Commit all current changes across as many focused commits as needed, not just the most obvious files.
- Prefer several small coherent commits over a few broad commits when the diff contains multiple behaviors or concerns.
- Use `git diff --stat`, `git diff`, and `git status --short` to confirm all changed files are accounted for.
- Stage hunks or files deliberately so each commit can stand on its own.
- After committing, verify the worktree is clean with `git status --short`.
- Do not leave unrelated modified files uncommitted after an explicit add/commit request unless the user asked to preserve them separately.

## Validation

- For UI-only SwiftUI menu changes, a successful release build is enough unless the user asks for runtime verification.
- Existing Swift concurrency warnings may appear in `ResticScheduler.swift`, `UserDefault.swift`, and `KeychainPassword.swift`; do not treat them as caused by small menu-order edits unless the changed code is implicated.
- Keep unrelated local changes intact. Do not clean DerivedData, delete app bundles, or reset git state unless the user asks.
