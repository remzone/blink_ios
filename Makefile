SHELL := /bin/bash
WIREGUARD_REV := 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1
FREETURN_REV := aed2839c7dea18d8ade99299fe77973d0730b00b
FREETURN_REPO := https://github.com/cacggghp/free-turn-proxy.git
XRAY_MOBILE_VERSION := v0.0.0-20261011034528-197770444867
MOBILE_VERSION := v0.0.0-20260709172247-6129f5bee9d5

.PHONY: bootstrap framework xray-framework icon project prepare archive clean

bootstrap:
	@command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
	@command -v go >/dev/null || { echo "Install Go 1.27.3+: brew install go"; exit 1; }
	@if [ ! -d Vendor/wireguard-apple/.git ]; then git clone https://github.com/WireGuard/wireguard-apple.git Vendor/wireguard-apple; fi
	@git -C Vendor/wireguard-apple fetch --depth 1 origin $(WIREGUARD_REV)
	@git -C Vendor/wireguard-apple checkout --detach $(WIREGUARD_REV)
	@if [ ! -d Vendor/free-turn-proxy/.git ]; then git clone $(FREETURN_REPO) Vendor/free-turn-proxy; fi
	@git -C Vendor/free-turn-proxy fetch --depth 1 $(FREETURN_REPO) $(FREETURN_REV)
	@git -C Vendor/free-turn-proxy checkout --detach $(FREETURN_REV)

framework: bootstrap
	go install golang.org/x/mobile/cmd/gomobile@$(MOBILE_VERSION)
	go install golang.org/x/mobile/cmd/gobind@$(MOBILE_VERSION)
	PATH="$$(go env GOPATH)/bin:$$PATH" "$$(go env GOPATH)/bin/gomobile" init
	mkdir -p Vendor/free-turn-proxy/dist
	cd Vendor/free-turn-proxy && PATH="$$(go env GOPATH)/bin:$$PATH" "$$(go env GOPATH)/bin/gomobile" bind -target ios,iossimulator -ldflags "-checklinkname=0 -s -w" -o dist/Mobile.xcframework ./mobile

icon:
	@sips -z 1024 1024 -s format png Blink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png --out Blink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png >/dev/null

xray-framework: framework
	go install golang.org/x/mobile/cmd/gomobile@$(XRAY_MOBILE_VERSION)
	go install golang.org/x/mobile/cmd/gobind@$(XRAY_MOBILE_VERSION)
	PATH="$$(go env GOPATH)/bin:$$PATH" "$$(go env GOPATH)/bin/gomobile" init
	mkdir -p Native/dist
	cd Native && PATH="$$(go env GOPATH)/bin:$$PATH" "$$(go env GOPATH)/bin/gomobile" bind -target ios,iossimulator -o dist/BlinkCore.xcframework ./mobile

project: framework xray-framework icon
	xcodegen generate

prepare: project
	@echo "Blink.xcodeproj is ready"

archive: prepare
	mkdir -p artifacts
	xcodebuild archive -project Blink.xcodeproj -scheme Blink -configuration Release -destination 'generic/platform=iOS' -archivePath artifacts/Blink.xcarchive

clean:
	rm -rf Blink.xcodeproj artifacts Vendor/free-turn-proxy/dist Native/dist
