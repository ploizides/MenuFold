# MenuFold

A tiny menu bar app for macOS 27 that folds away the menu bar icons you don't need. Click the chevron to hide them, and click again to bring them back.


#### Unfolded:
<img width="516" height="31" alt="image" src="https://github.com/user-attachments/assets/3f29548a-1096-4bf1-9ef8-eb052d17dd72" />

#### Folded:
<img width="487" height="37" alt="image" src="https://github.com/user-attachments/assets/5edf7876-a035-496c-9589-ff7ea23efd1a" />



## Why another one?

Menu bar managers like Ice stopped hiding icons for us on macOS 27.

The classic trick is a hidden divider that gets stretched to 10,000 px so every icon to its left is pushed off the screen. On macOS 27 the menu bar is drawn by a new system process (`MenuBarAgent`), which **hides the stretched divider itself** rather than moving anything. The divider vanishes and every icon stays where it was.

MenuFold stretches the divider only as far as the notch. The icons to its left then no longer fit, and macOS hides them the same way it hides icons that don't fit next to the notch. It uses only public APIs, so it needs **no Accessibility or Screen Recording permission**.

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

### Option 2: Build it yourself

You need Apple's command line tools. Run `xcode-select --install` if you don't have them.

```bash
git clone https://github.com/ploizides/MenuFold.git
cd MenuFold
./build.sh install
```

The app is built on your own Mac, so macOS won't show a warning.

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
- It's tuned for MacBooks with a notch. External displays without a notch use a best guess (the middle of the screen).
- Requires macOS 14 or later. Built and tested on macOS 27.2 (Apple Silicon). The Intel build is included but untested.

## Uninstall

Quit it from the right-click menu, then delete `MenuFold.app`.
