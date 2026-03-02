.PHONY: xcframework clean project build run

# Build the GhosttyKit xcframework from the vendored Ghostty source.
xcframework:
	cd vendor/ghostty && zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native
	mkdir -p xcframework
	cp -R vendor/ghostty/macos/GhosttyKit.xcframework xcframework/

# Generate Xcode project from project.yml
project:
	xcodegen generate

# Build the app
build: project
	xcodebuild -scheme PJTerminal -configuration Debug build

# Run the built app
run:
	open ~/Library/Developer/Xcode/DerivedData/PJTerminal-*/Build/Products/Debug/PJTerminal.app

clean:
	rm -rf xcframework/GhosttyKit.xcframework
	rm -rf PJTerminal.xcodeproj
