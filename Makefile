APP_NAME := AgentLimits
BUNDLE   := build/$(APP_NAME).app
CONFIG   ?= release
ICON     := build/AppIcon.icns

.PHONY: all build app run test clean install dump

all: app

build:
	swift build -c $(CONFIG)

$(ICON): Resources/AppIcon.png
	rm -rf build/AppIcon.iconset
	mkdir -p build/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s $< --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) $< --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o $@
	rm -rf build/AppIcon.iconset

app: build $(ICON)
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	cp $(ICON) "$(BUNDLE)/Contents/Resources/AppIcon.icns"
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
