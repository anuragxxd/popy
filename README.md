# Popy

A tiny macOS menu bar app that remembers what you copy.

Click any past copy to use it again — that's it.

## Install

One command:

```bash
curl -fsSL https://raw.githubusercontent.com/anuragxxd/popy/master/install.sh | bash
```

Or **[download the DMG manually](https://github.com/anuragxxd/popy/releases/latest)** — open it, drag Popy to Applications, done.

## What it does

- Sits quietly in your menu bar
- Remembers your last 25 text copies
- Click any entry to copy it back (or paste it directly into the active app)
- Survives restarts — your history is saved
- No dock icon, no windows, no clutter

## Settings

All toggleable from the menu:

- **Click to Copy** or **Click to Paste Directly** — choose what happens when you click an entry
- **Sound on Copy** — subtle audio feedback
- **Launch at Login** — start Popy automatically

> "Paste Directly" mode simulates Cmd+V into whatever app you're using. macOS will ask for Accessibility permission the first time.

## Requirements

macOS 12 (Monterey) or later.

## Contribute

Issues and PRs welcome at [github.com/anuragxxd/popy](https://github.com/anuragxxd/popy).

To build from source:

```
git clone https://github.com/anuragxxd/popy.git
cd popy
bash setup.sh
```

## License

MIT
