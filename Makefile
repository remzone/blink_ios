SHELL := /bin/bash
XRAY_MOBILE_VERSION := v0.0.0-20261011034528-197770444867

.PHONY: bootstrap xray-framework icon project prepare archive clean

bootstrap:
	@command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
	@command -v go >/dev/null || { echo "Install Go 1.27.3+"; exit 1; }

icon:
	@sips -z 1024 1024 -s format png Blink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png --out Blink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png >/dev/null

xray-framework: bootstrap
	go install golang.org/x/mobile/cmd/gomobile@$(XRAY_MOBILE_VERSION)
	go install golang.org/x/mobile/cmd/gobind@$(XRAY_MOBILE_VERSION)
	PATH="$$(go env GOPATH)/bin:$$PATH" "$$(go env GOPATH)/bin/gomobile" init
	mkdir -p Native/dist
	cd Native && PATH="$$(go env GOPATH)/bin:$$PATH" "$$(go env GOPATH)/bin/gomobile" bind -target ios,iossimulator -iosversion=16.0 -ldflags "-checklinkname=0 -s -w" -o dist/BlinkCore.xcframework ./mobile

project: xray-framework icon
	xcodegen generate

prepare: project
	@echo "Blink.xcodeproj is ready"

archive: prepare
	mkdir -p artifacts
	xcodebuild archive -project Blink.xcodeproj -scheme Blink -configuration Release -destination 'generic/platform=iOS' -archivePath artifacts/Blink.xcarchive

clean:
	rm -rf Blink.xcodeproj artifacts Vendor/free-turn-proxy/dist Native/dist
