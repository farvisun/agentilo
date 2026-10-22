APP_NAME := AgentLimits
BUNDLE   := build/$(APP_NAME).app
CONFIG   ?= release

.PHONY: all build app run test clean install dump

all: app

build:
	swift build -c $(CONFIG)

app: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign - --timestamp=none "$(BUNDLE)"
	@echo "Built $(BUNDLE)"

run: app
	-pkill -x $(APP_NAME)
	open "$(BUNDLE)"

dump: build
	"$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" --dump $(ARGS)

install: app
	-pkill -x $(APP_NAME)
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(BUNDLE)" /Applications/
	open "/Applications/$(APP_NAME).app"

test:
	swift test

clean:
	rm -rf build .build
