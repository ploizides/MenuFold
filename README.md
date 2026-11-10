# MenuFold

A tiny menu bar app for macOS 27 that folds away the menu bar icons you don't need. Click the chevron to hide them, and click again to bring them back.


#### Unfolded:
<img width="516" height="31" alt="image" src="https://github.com/user-attachments/assets/3f29548a-1096-4bf1-9ef8-eb052d17dd72" />

#### Folded:
<img width="487" height="37" alt="image" src="https://github.com/user-attachments/assets/5edf7876-a035-496c-9589-ff7ea23efd1a" />



## Why another one?

Menu bar managers like Ice stopped hiding icons for us on macOS 27.

The classic trick is a hidden divider that gets stretched to 10,000 px so every icon to its left is pushed off the screen. On macOS 27 the menu bar is drawn by a new system process (`MenuBarAgent`), which **hides the stretched divider itself** rather than moving anything. The divider vanishes and every icon stays where it was.

MenuFold stretches the divider exactly as far as the free space goes. On a MacBook that means up to the notch; on an external monitor it means up to where the current app's menus end. The icons to its left then no longer fit, and macOS hides them the same way it hides icons that don't fit next to the notch. It needs **no Screen Recording permission**, and the Device Control and Data Access permission (Accessibility on older macOS) is optional (see below).

## Install

### Option 1: Download (easiest)

1. Download `MenuFold.zip` from the [latest release](https://github.com/ploizides/MenuFold/releases/latest).
2. Unzip it and drag `MenuFold.app` into **Applications**.
3. Open it. macOS will say it *"could not verify"* the app, because it isn't signed with a paid Apple developer account.
   - Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   - Or run this once in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/MenuFold.app
     ```

### Option 2: Homebrew

```bash
brew tap ploizides/menufold https://github.com/ploizides/MenuFold
brew install --cask ploizides/menufold/menufold
```

Homebrew clears the "could not verify" flag for you, so it opens straight away. Run `brew upgrade` to update to new versions, and `brew uninstall --cask menufold` to remove it.

### Option 3: Build it yourself

You need Apple's command line tools. Run `xcode-select --install` if you don't have them.

```bash
git clone https://github.com/ploizides/MenuFold.git
cd MenuFold
./build.sh install
```

The app is built on your own Mac, so macOS won't show a warning.

## Releasing a new version (maintainers)

Pushing to `main` does **not** update the download. The release zip is a snapshot. To ship changes:

1. Bump `CFBundleShortVersionString` in `Info.plist` (e.g. `1.1`).
2. `./build.sh zip`, which builds the zip and updates `Casks/menufold.rb`.
3. Commit and push, then `gh release create v1.1 build/MenuFold.zip`.

## Use

- **Hold ⌘ and drag** icons to arrange them. Icons **left of `│`** get hidden, and icons **right of the chevron** always stay visible.
- **Click the chevron** to fold or unfold.
- **Right-click the chevron** to open Settings or quit.
- When folded, macOS shows its own **`«`** button. Click it to peek at the hidden icons without unfolding.

Keep the chevron to the right of `│`. If it ends up on the wrong side, MenuFold won't fold, so it can't hide its own button. **Settings → Reset positions** puts both back.

## Settings

| Setting | What it does |
|---|---|
| Fold at launch | Folds automatically when the app starts |
| Re-fold after… | Folds again 5 s – 1 min after you unfold |
| Keyboard shortcut | ⌥⌘B, ⌃⌥⌘M or ⌃⌥Space to fold or unfold from anywhere |
| Launch at login | Starts MenuFold when you log in |
| Toggle icon / Divider | Chevron, circle or ellipsis, and a line or dot divider |

## Good to know

- Quit Ice, Bartender or Hidden Bar first so they don't fight over the menu bar.
- If MenuFold's icons disappear, check **System Settings → Menu Bar** and make sure MenuFold is allowed.
- **External monitors:** MenuFold folds on whichever screen's menu bar you're using and re-measures when you move between screens or switch apps. Without the optional **Accessibility** permission, it finds the edge by trial and error, so the first fold for each app on a monitor makes icons flash for about 2 seconds (it remembers the result after that). Grant the optional **Device Control and Data Access** permission (called Accessibility on older macOS) in MenuFold's **Settings → Permissions** to make it instant. The laptop screen never needs it.
- After updating MenuFold, that permission switch may still look on in System Settings but no longer apply, because macOS treats each unsigned build as a new app. Click **Reset & Grant again** in MenuFold's Settings → Permissions.
- Requires macOS 14 or later. Built and tested on macOS 27.2 (Apple Silicon). The Intel build is included but untested.

## Uninstall

Quit it from the right-click menu, then delete `MenuFold.app`.
