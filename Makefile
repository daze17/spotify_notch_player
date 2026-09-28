PROJECT := NotchPlayer.xcodeproj
SCHEME  := NotchPlayer
CONFIG  ?= Debug
DERIVED := build
APP     := $(DERIVED)/Build/Products/$(CONFIG)/NotchPlayer.app

# Optional: `make build TEAM=XXXXXXXXXX` signs with your Apple Development identity
# instead of ad-hoc, so the Automation permission survives rebuilds.
ifdef TEAM
SIGN_FLAGS := DEVELOPMENT_TEAM=$(TEAM) CODE_SIGN_IDENTITY="Apple Development"
endif

.PHONY: gen build run clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) $(SIGN_FLAGS) build

run: build
	-pkill -x NotchPlayer
	open $(APP)

clean:
	rm -rf $(DERIVED) $(PROJECT)
