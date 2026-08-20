APP_NAME = Imperator FinderTerminal
BUNDLE   = build/$(APP_NAME).app
DIST     = dist
ZIP      = $(DIST)/Imperator-FinderTerminal-$(VERSION).zip
BUILD_NUMBER = $(shell git rev-list --count HEAD)
# What `release` stamps, and it is not BUILD_NUMBER. `release` makes one commit
# before it tags, but every use of BUILD_NUMBER in that target expands BEFORE
# that commit exists — so the number counts every commit except the release's
# own, and the build the tag points at claims to be one older than it is.
# Shipped that way three times: v1.0.0 carries 21 against 22 commits, v1.0.1
# carries 23 against 24, v1.0.2 carries 25 against 26. Same count plus the
# commit `release` is about to make.
RELEASE_BUILD_NUMBER = $(shell git rev-list --count HEAD | awk '{print $$1 + 1}')
# Optional lead sentence for the release notes, e.g. NOTES="Fixes the ... bug."
NOTES ?=

.PHONY: all release-build install clean dist release check-version

# Everything routes through build.sh -- it is the single build recipe.
all:
	./build.sh

release-build:
	./build.sh release

install: release-build
	@killall FinderTerminal 2>/dev/null || true
	@sleep 0.5
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(BUNDLE)" "/Applications/$(APP_NAME).app"
	open "/Applications/$(APP_NAME).app"
	@echo "Installed: /Applications/$(APP_NAME).app"

clean:
	rm -rf build .build

check-version:
	@test -n "$(VERSION)" || { echo "Usage: make $(MAKECMDGOALS) VERSION=x.y.z"; exit 1; }

# Build a distributable zip. Signed with the same "Imperator Dev" identity as a
# local build: the designated requirement then pins that certificate instead of
# the binary's hash, so the Accessibility and Input Monitoring grants survive an
# update. Ad-hoc signing would reset all three permissions on every version.
# Touches nothing in git, nothing on the remote.
dist: check-version release-build
	@mkdir -p $(DIST)
	rm -f "$(ZIP)"
	# Stamp the version into the built bundle, not the source: a test zip then
	# reports the version it will ship as, without dirtying the working tree.
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(BUNDLE)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign "$${CODESIGN_IDENTITY:-Imperator Dev}" \
		--entitlements Resources/FinderTerminal.entitlements "$(BUNDLE)"
	ditto -c -k --sequesterRsrc --keepParent "$(BUNDLE)" "$(ZIP)"
	@echo "Packaged: $(ZIP)"

# Bump version, commit, tag, push, publish the GitHub release with the zip attached.
release: check-version
	@git diff --quiet && git diff --cached --quiet || { echo "Working tree dirty -- commit first."; exit 1; }
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Resources/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(RELEASE_BUILD_NUMBER)" Resources/Info.plist
	# Handed down explicitly, so the zip and the source plist agree. `dist` on its
	# own is a test build that makes no commit, and there its plain count is right.
	$(MAKE) dist VERSION=$(VERSION) BUILD_NUMBER=$(RELEASE_BUILD_NUMBER)
	git add Resources/Info.plist
	git commit -m "Release v$(VERSION)"
	git tag -a v$(VERSION) -m "$(APP_NAME) $(VERSION)"
	git push origin HEAD
	git push origin v$(VERSION)
	gh release create v$(VERSION) \
		--title "$(APP_NAME) $(VERSION)" \
		--notes "$(NOTES)A keyboard-triggered terminal that docks beside the frontmost real Finder window. Requires macOS 14 or later, Apple silicon; built and tested on macOS 26 only. Accessibility, Automation and Input Monitoring have to be granted in System Settings. Self-signed and not notarized, so Gatekeeper blocks the first launch: right-click the app and choose Open, or run \`xattr -dr com.apple.quarantine \"/Applications/$(APP_NAME).app\"\`." \
		"$(ZIP)#$(APP_NAME) $(VERSION) (macOS)"
	@echo "Released v$(VERSION)"
