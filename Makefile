CLANG ?= xcrun clang
IOS_SDK ?= $(HOME)/Downloads/AppleTV3/theos-sdks/iPhoneOS11.4.sdk
MIN_IOS ?= 8.0
BUILD ?= build/$(notdir $(IOS_SDK))-ios$(MIN_IOS)
SOURCES := $(wildcard Sources/*.m Sources/API/*.m Sources/BackRow/*.m Sources/Input/*.m Sources/Navigation/*.m Sources/Playback/*.m)
OBJECTS := $(patsubst Sources/%.m,$(BUILD)/armv7/%.o,$(SOURCES))
COMMON := -fblocks -fno-objc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -ISources
ARM_EXTRA_FLAGS ?=
ARMFLAGS := -target armv7-apple-ios$(MIN_IOS) -isysroot "$(IOS_SDK)" $(COMMON) $(ARM_EXTRA_FLAGS)
.PHONY: all shell armv7-objects test test-http clean
all: shell
armv7-objects: $(OBJECTS)
$(BUILD)/armv7/%.o: Sources/%.m
	@mkdir -p $(@D)
	$(CLANG) $(ARMFLAGS) -MMD -MP -c $< -o $@
shell: armv7-objects
	@mkdir -p $(BUILD)/Jellyfin.frappliance
	cp Jellyfin.frappliance/Info.plist $(BUILD)/Jellyfin.frappliance/
	cp Jellyfin.frappliance/AppIcon.png $(BUILD)/Jellyfin.frappliance/
	cp Jellyfin.frappliance/TopRowIcon.png $(BUILD)/Jellyfin.frappliance/
	cp -R Jellyfin.frappliance/English.lproj $(BUILD)/Jellyfin.frappliance/
	$(CLANG) $(ARMFLAGS) -bundle $(OBJECTS) -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText -lobjc -o $(BUILD)/Jellyfin.frappliance/Jellyfin
	python3 Scripts/check-v2-audio-build.py $(BUILD)/Jellyfin.frappliance/Jellyfin
build/tests: $(SOURCES) $(wildcard Sources/*/*.h) Tests/main.m Tests/JFFixtureProtocol.m Tests/JFDeviceABIFixture.h
	@mkdir -p build
	$(CLANG) $(COMMON) -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/main.m Tests/JFFixtureProtocol.m -o $@
test: build/tests
	./build/tests http://fixture.invalid
test-http: build/tests
	python3 Tests/run.py
clean:
	@echo "Historical builds are protected; use a new BUILD directory for a clean build."
	@false
-include $(OBJECTS:.o=.d)

build/integration: $(SOURCES) $(wildcard Sources/*/*.h) Tests/integration.m Tests/JFFixtureProtocol.m
	@mkdir -p build
	$(CLANG) $(COMMON) -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/integration.m Tests/JFFixtureProtocol.m -o $@
test-integration-fixture: build/integration
	python3 Tests/integration.py --fixture
test-integration: build/integration
	python3 Tests/integration.py
test-tls-negative: build/tests build/integration
	python3 Tests/run.py --self-signed

.PHONY: test-integration-entry test-integration-fixture test-integration test-tls-negative
test-integration-entry: build/integration
	python3 Tests/integration_test.py

build/session-tests: $(SOURCES) $(wildcard Sources/*/*.h) Tests/session.m
	@mkdir -p build
	$(CLANG) $(COMMON) -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/session.m -o $@
.PHONY: test-session
test-session: build/session-tests
	./build/session-tests

build/host-tests: $(SOURCES) $(wildcard Sources/*/*.h) Tests/host.m Tests/JFFixtureProtocol.m
	@mkdir -p build
	$(CLANG) $(COMMON) -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/host.m Tests/JFFixtureProtocol.m -o $@
.PHONY: test-host test-phase4c
test-host: build/host-tests
	./build/host-tests
test-phase4c: test test-session test-host test-integration-entry

.PHONY: test-integration-http
test-integration-http: build/integration
	python3 Tests/run.py --integration

build/ui-tests: $(SOURCES) $(wildcard Sources/*/*.h) Tests/ui.m Tests/JFFixtureProtocol.m Tests/JFDeviceABIFixture.h
	@mkdir -p build
	$(CLANG) $(COMMON) -DJF_AUDIO_GATE_HOST_FIXTURE -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/ui.m Tests/JFFixtureProtocol.m -o $@
.PHONY: test-ui test-phase4d
test-ui: build/ui-tests
	./build/ui-tests
	./build/ui-tests bad-menu
	./build/ui-tests bad-protocol
	./build/ui-tests bad-password
	./build/ui-tests bad-list
	./build/ui-tests bad-category
	./build/ui-tests missing-category
	./build/ui-tests missing-category-selector
	./build/ui-tests missing-protocol
	./build/ui-tests missing-selector
	./build/ui-tests missing-text-protocol
	./build/ui-tests bad-init
	./build/ui-tests bad-int-selection
	./build/ui-tests bad-event
test-phase4d: test-phase4c test-ui

build/playback-tests: $(SOURCES) $(wildcard Sources/*/*.h) Tests/playback.m Tests/JFPlaybackFixture.m
	@mkdir -p build
	$(CLANG) $(COMMON) -DJF_AUDIO_GATE_HOST_FIXTURE -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/playback.m Tests/JFPlaybackFixture.m -o $@
.PHONY: test-playback
test-playback: build/playback-tests
	./build/playback-tests

build/playback-http: $(SOURCES) $(wildcard Sources/*/*.h) Tests/playback_http.m
	@mkdir -p build
	$(CLANG) $(COMMON) -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/playback_http.m -o $@
.PHONY: test-playback-http test-tls-contracts test-python
test-playback-http: build/playback-http
	python3 Tests/run.py --playback
test-tls-contracts:
	python3 Tests/tls_test.py
test-python: build/integration
	python3 Tests/integration_test.py
	python3 Tests/package_test.py
	python3 Tests/deployment_test.py

.PHONY: test-offline test-asan
test-offline: test-phase4d test-playback test-integration-fixture test-python
# Separate binaries, no clean/removal of historical artifacts.
ASAN_FLAGS := -fsanitize=address -fno-omit-frame-pointer -g
build/playback-asan: $(SOURCES) $(wildcard Sources/*/*.h) Tests/playback.m Tests/JFPlaybackFixture.m
	$(CLANG) $(COMMON) $(ASAN_FLAGS) -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/playback.m Tests/JFPlaybackFixture.m -o $@
build/ui-asan: $(SOURCES) $(wildcard Sources/*/*.h) Tests/ui.m Tests/JFFixtureProtocol.m Tests/JFDeviceABIFixture.h
	$(CLANG) $(COMMON) $(ASAN_FLAGS) -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/ui.m Tests/JFFixtureProtocol.m -o $@
build/session-asan: $(SOURCES) $(wildcard Sources/*/*.h) Tests/session.m
	$(CLANG) $(COMMON) $(ASAN_FLAGS) -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/session.m -o $@
test-asan: build/playback-asan build/ui-asan build/session-asan
	ASAN_OPTIONS=detect_leaks=0 ./build/playback-asan
	ASAN_OPTIONS=detect_leaks=0 ./build/ui-asan
	ASAN_OPTIONS=detect_leaks=0 ./build/session-asan

.PHONY: test-local-srt
build/local-srt-tests: $(SOURCES) $(wildcard Sources/*/*.h) Tests/local_subtitle.m
	$(CLANG) $(COMMON) -framework Foundation -framework Security -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreText $(SOURCES) Tests/local_subtitle.m -o $@
test-local-srt: build/local-srt-tests
	./build/local-srt-tests
