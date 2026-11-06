APP := resto.app

DEST := /Applications/resto.app

# En el SDK 27 `@State` es una macro cuyo plugin las Command Line Tools no traen: con Xcode
# instalado esto sobra. ponytail: se cae cuando Apple borre el 26.5 de las CLT.
export SDKROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

.PHONY: app install run clean test

# macOS sólo trata la app como accesoria (sin Dock) si vive en un bundle con Info.plist.
app: $(APP)

$(APP): Info.plist Icon/resto.icns $(wildcard Sources/resto/*.swift)
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/resto $(APP)/Contents/MacOS/resto
	cp Info.plist $(APP)/Contents/Info.plist
	cp Icon/resto.icns $(APP)/Contents/Resources/resto.icns
	codesign --force --sign - $(APP)
	touch $(APP)

# La app del día a día vive en /Applications para no depender de dónde esté el repo.
# El bundle se arma igual acá y se copia: así `make clean` nunca toca /Applications.
install: app
	pkill -x resto || true
	rm -rf $(DEST)
	cp -R $(APP) $(DEST)
	open $(DEST)

# Para probar el build sin tocar la copia instalada.
run: app
	pkill -x resto || true
	open $(APP)

test:
	swift build && .build/debug/resto --self-test && echo "self-test OK"

clean:
	rm -rf $(APP) .build
