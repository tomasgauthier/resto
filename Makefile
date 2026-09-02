APP := resto.app

DEST := /Applications/resto.app

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
