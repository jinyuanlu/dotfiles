# Dotfiles

## Karabiner Keyboard Shortcuts Cheatsheet

### Emacs-style Navigation
| Shortcut | Action | Notes |
|----------|--------|-------|
| `C-n` | Down arrow | Disabled in Terminal/Emacs |
| `C-p` | Up arrow | Disabled in Terminal/Emacs |
| `C-f` | Right arrow | Disabled in Terminal/Emacs |
| `C-b` | Left arrow | Disabled in Terminal/Emacs |
| `C-a` | Home (line start) | Disabled in Terminal/Emacs |
| `C-e` | End (line end) | Disabled in Terminal/Emacs |

### Emacs-style Scrolling
| Shortcut | Action | Notes |
|----------|--------|-------|
| `C-v` | Page Down | Disabled in Emacs |
| `M-v` | Page Up | Disabled in Emacs |
| `C-Shift-n` | Smooth scroll down | Mouse wheel simulation |
| `C-Shift-p` | Smooth scroll up | Mouse wheel simulation |

### Emacs-style Word Navigation
| Shortcut | Action | Notes |
|----------|--------|-------|
| `M-f` | Word forward | Option + right arrow |
| `M-b` | Word backward | Option + left arrow |

### Emacs-style Editing
| Shortcut | Action | Notes |
|----------|--------|-------|
| `C-d` | Delete forward | Disabled in Terminal/Emacs |
| `C-h` | Backspace | Disabled in Terminal/Emacs |
| `C-k` | Kill line | Delete to end of line |

### Tab + Mouse Control
| Shortcut | Action | Notes |
|----------|--------|-------|
| `Tab` (alone) | Tab | Normal tab key |
| `Tab+W` | Mouse up | Fast movement (2300px) |
| `Tab+A` | Mouse left | Fast movement (2300px) |
| `Tab+S` | Mouse down | Fast movement (2300px) |
| `Tab+D` | Mouse right | Fast movement (2300px) |
| `Tab+Shift+W` | Mouse up | Slow movement (256px) |
| `Tab+Shift+A` | Mouse left | Slow movement (256px) |
| `Tab+Shift+S` | Mouse down | Slow movement (256px) |
| `Tab+Shift+D` | Mouse right | Slow movement (256px) |
| `Tab+Space` | Left click | Mouse button 1 |
| `Tab+Return` | Left click | Mouse button 1 |
| `Tab+Shift+Space` | Middle click | Mouse button 2 |
| `Tab+Ctrl+Space` | Right click | Mouse button 3 |

### Tab Sublayer: Open Apps (Tab+O)
| Shortcut | Action | Application |
|----------|--------|-------------|
| `Tab+O, T` | Open Terminal | Terminal.app |
| `Tab+O, E` | Open Emacs | Emacs.app |
| `Tab+O, C` | Open Chrome | Google Chrome.app |
| `Tab+O, F` | Open Finder | Finder.app |
| `Tab+O, S` | Open Slack | Slack.app |
| `Tab+O, V` | Open VS Code | Visual Studio Code.app |

### Tab Sublayer: Window Management (Tab+R)
| Shortcut | Action | Notes |
|----------|--------|-------|
| `Tab+R, H` | Window left half | Rectangle integration |
| `Tab+R, L` | Window right half | Rectangle integration |
| `Tab+R, J` | Window bottom half | Rectangle integration |
| `Tab+R, K` | Window top half | Rectangle integration |
| `Tab+R, F` | Maximize window | Rectangle integration |
| `Tab+R, C` | Center window | Rectangle integration |
| `Tab+R, N` | Next display | Move to next monitor |
| `Tab+R, P` | Previous display | Move to previous monitor |

### Tab Sublayer: System Control (Tab+C)
| Shortcut | Action | Notes |
|----------|--------|-------|
| `Tab+C, U` | Volume up | System volume |
| `Tab+C, D` | Volume down | System volume |
| `Tab+C, M` | Mute | Toggle mute |
| `Tab+C, I` | Brightness up | Display brightness |
| `Tab+C, K` | Brightness down | Display brightness |
| `Tab+C, P` | Play/Pause | Media control |
| `Tab+C, N` | Next track | Media control |
| `Tab+C, B` | Previous track | Media control |
| `Tab+C, L` | Lock screen | Ctrl+Cmd+Q |

### Function Keys
| Key | Action |
|-----|--------|
| `F1` | Brightness down |
| `F2` | Brightness up |
| `F3` | Mission Control |
| `F4` | Spotlight |
| `F5` | Dictation |
| `F6` | F6 (passthrough) |
| `F7` | Rewind |
| `F8` | Play/Pause |
| `F9` | Fast Forward |
| `F10` | Mute |
| `F11` | Volume down |
| `F12` | Volume up |

## Usage Notes

- **Tab as modifier**: Hold Tab to activate mouse control or sublayers
- **Sublayers**: After pressing Tab+O/R/C, release Tab but keep holding the sublayer key, then press the action key
- **App exclusions**: Emacs-style bindings are disabled in Terminal and Emacs to avoid conflicts
- **Rectangle required**: Window management shortcuts require Rectangle app to be installed