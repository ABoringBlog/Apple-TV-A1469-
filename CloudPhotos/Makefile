SDKROOT ?= /path/to/your/legally-obtained/compatible/sdk
CLANG ?= clang
OUT := build/CloudPhotos.frappliance
SRC := $(wildcard Sources/CloudPhotos/*.m)
CFLAGS := -arch armv7 -isysroot $(SDKROOT) -miphoneos-version-min=8.0 -fno-objc-arc -fblocks -I Sources/CloudPhotos
LDFLAGS := -framework Foundation -framework CoreGraphics -framework CoreText -framework ImageIO -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework UIKit -framework QuartzCore -framework Security -lobjc
all:
	@test -f Sources/CloudPhotos/CloudPhotosPublicConfig.h || (echo "Create local CloudPhotosPublicConfig.h (not checked in)" && exit 1)
	mkdir -p $(OUT)/English.lproj
	cp Resources/Info.plist $(OUT)/Info.plist
	cp Resources/English.lproj/InfoPlist.strings $(OUT)/English.lproj/InfoPlist.strings
	$(CLANG) $(CFLAGS) -dynamiclib $(SRC) $(LDFLAGS) -o $(OUT)/CloudPhotos
