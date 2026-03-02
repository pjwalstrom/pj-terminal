# pj-terminal

A minimal macOS terminal emulator powered by [GhosttyKit](https://ghostty.org/) — the embedding framework from the [Ghostty](https://github.com/ghostty-org/ghostty) terminal emulator.

**This entire project was built using [GitHub Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli) in a single interactive session.** This README documents the process and what was learned.

## What it does

pj-terminal is a working macOS terminal app in ~280 lines of Swift. It renders a full GPU-accelerated terminal via Metal, handles keyboard/mouse/scroll input, and spawns your default shell — all by delegating to Ghostty's battle-tested terminal engine through its C embedding API.

### Architecture

```
PJTerminal/
├── main.swift                  # Entry point — calls ghostty_init(), then starts SwiftUI
├── PJTerminalApp.swift         # SwiftUI App with a single WindowGroup
├── ContentView.swift           # Wraps the terminal surface in SwiftUI
├── TerminalRuntime.swift       # Singleton managing the ghostty_app_t lifecycle
└── TerminalSurfaceView.swift   # NSView hosting ghostty_surface_t (rendering + input)
```

The design follows TermBridgeKit's minimal 4-file pattern: a runtime singleton manages the Ghostty app instance and tick loop, while an NSView subclass owns the terminal surface and forwards all AppKit events to Ghostty's C API.

## How it was built — the Copilot CLI journey

This project was created entirely through conversation with GitHub Copilot CLI (`copilot-cli`). Here's what the process looked like, including the problems hit and how they were resolved.

### 1. Research & design decisions

The session started with "I'd like to create a terminal emulator based on libghostty." Copilot CLI researched the ecosystem and presented choices:

- **libghostty vs libghostty-vt**: The full `libghostty` (aka GhosttyKit) provides complete terminal embedding with rendering, input handling, and shell management. `libghostty-vt` is a standalone VT parser only. We chose the full framework.
- **Reference projects discovered**: [fantastty](https://github.com/blaine/fantastty) (full macOS app), [TermBridgeKit](https://github.com/arach/TermBridgeKit) (minimal SwiftUI wrapper), and the [awesome-libghostty](https://github.com/niclas-pj/awesome-libghostty) curated list.
- **Architecture chosen**: Swift + SwiftUI + AppKit hybrid (SwiftUI for the window, AppKit NSView for the terminal surface — required by GhosttyKit's Metal rendering).

### 2. Toolchain setup

Copilot CLI installed the required tools via Homebrew:

```bash
brew install zig          # Zig 0.15.2 — Ghostty's build system
brew install xcodegen     # Generates .xcodeproj from a YAML spec
```

Ghostty was added as a git submodule:

```bash
git submodule add https://github.com/ghostty-org/ghostty.git vendor/ghostty
```

### 3. Building GhosttyKit — the hard part

This is where most of the debugging happened. The build command is conceptually simple:

```bash
cd vendor/ghostty
zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native
```

But several blockers were hit and resolved:

#### Blocker 1: iOS targets crash with Command Line Tools only

The xcframework build step unconditionally creates iOS and iOS Simulator targets, even when `-Dxcframework-target=native` is set. With only Xcode Command Line Tools installed (no full Xcode), this crashes because there are no iOS SDKs.

**Fix**: Copilot CLI patched `vendor/ghostty/src/build/GhosttyXCFramework.zig` to skip iOS target creation when building in `native` mode. This is a local-only patch.

#### Blocker 2: Metal shader compiler not found

GhosttyKit compiles Metal shaders during the build. The `metal` compiler is only available with full Xcode, not Command Line Tools.

**Fix**: Install Xcode from the App Store, then:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

#### Blocker 3: Metal Toolchain component missing

Even with Xcode installed, the Metal toolchain component needed to be downloaded separately (704 MB):

```bash
xcodebuild -downloadComponent MetalToolchain
```

After resolving all three, the build produced `GhosttyKit.xcframework` containing a static library and C headers for macOS arm64.

### 4. Writing the Swift code

Copilot CLI studied Ghostty's own macOS source (`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`) and TermBridgeKit's minimal wrapper to understand the GhosttyKit C API, then generated all five Swift source files.

Key API patterns learned:

```swift
// Lifecycle: init → config → app → surface
ghostty_init(argc, argv)
let config = ghostty_config_new()
ghostty_config_load_default_files(config)
ghostty_config_finalize(config)
let app = ghostty_app_new(&runtime_callbacks, config)

// Surface needs an NSView pointer for Metal rendering
var cfg = ghostty_surface_config_new()
cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
    nsview: Unmanaged.passUnretained(self).toOpaque()
))
let surface = ghostty_surface_new(app, &cfg)

// Must tick at 60fps and draw each frame
ghostty_app_tick(app)
ghostty_surface_draw(surface)

// Input goes through ghostty_surface_key() for all key events
ghostty_surface_key(surface, keyEvent)
ghostty_surface_mouse_button(surface, state, button, mods)
ghostty_surface_mouse_pos(surface, x, y, mods)
ghostty_surface_mouse_scroll(surface, dx, dy, mods)
```

### 5. Build errors & fixes

The first compile attempt had one error: `ghostty_surface_key_flags_changed` doesn't exist. Copilot CLI checked Ghostty's source and found that modifier key changes (`flagsChanged:`) should go through the regular `ghostty_surface_key()` function with the appropriate press/release action — matching how Ghostty itself handles it. Fixed in one edit, and the build succeeded.

### 6. Result

The app compiled, launched, and runs a terminal with the default shell. Total source code: ~280 lines of Swift across 5 files, plus a `project.yml` for XcodeGen and a `Makefile` for convenience.

## Prerequisites

- **macOS 14.0+** (Sonoma or later)
- **Xcode** (full install, not just Command Line Tools — needed for Metal compiler)
- **Zig 0.15.2** — `brew install zig`
- **XcodeGen** — `brew install xcodegen`

## Building

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/pjwalstrom/pj-terminal.git
cd pj-terminal

# Build GhosttyKit (takes a few minutes)
make xcframework

# Generate Xcode project and build
make build

# Run
make run
```

Or open `PJTerminal.xcodeproj` in Xcode after running `make xcframework && make project`.

## Current limitations

- **No clipboard support** — copy/paste callbacks are no-ops
- **No tab/split support** — single terminal window only
- **No configuration UI** — uses Ghostty's default config files (`~/.config/ghostty/config`)
- **macOS arm64 only** — the xcframework is built for Apple Silicon

## See also

**[pj-terminal-vt](https://github.com/pjwalstrom/pj-terminal-vt)** — A companion project that builds a terminal emulator using only `libghostty-vt`, Ghostty's lightweight standalone VT parser library. Unlike this project which delegates rendering and input to GhosttyKit's full embedding framework, pj-terminal-vt implements its own PTY management, VT state machine, screen buffer, and CoreText renderer (~900 lines of Swift). It uses libghostty-vt for SGR attribute parsing, OSC command parsing, and key encoding. Also built entirely with GitHub Copilot CLI.

## Acknowledgments

- [Ghostty](https://ghostty.org/) by Mitchell Hashimoto — the terminal engine
- [TermBridgeKit](https://github.com/arach/TermBridgeKit) — clean minimal reference architecture
- [fantastty](https://github.com/blaine/fantastty) — full-featured GhosttyKit macOS app
- [awesome-libghostty](https://github.com/niclas-pj/awesome-libghostty) — curated list of libghostty projects

## License

MIT
