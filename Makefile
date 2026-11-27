.PHONY: app check icon run install uninstall selftest clean

APP := build/VoiceFlow.app
INSTALL_DIR := $(HOME)/Applications

app:            ## Build build/VoiceFlow.app
	./scripts/build-app.sh

icon:           ## Regenerate Resources/AppIcon.icns and the menu-bar glyph
	swift scripts/make-icon.swift

check:          ## Run the unit checks
	swift run voiceflow-checks

run: app        ## Build and launch from build/
	open $(APP)

install: app    ## Install to ~/Applications and launch
	-pkill -x VoiceFlow
	rm -rf "$(INSTALL_DIR)/VoiceFlow.app"
	mkdir -p "$(INSTALL_DIR)"
	cp -R $(APP) "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/VoiceFlow.app"

uninstall:
	-pkill -x VoiceFlow
	rm -rf "$(INSTALL_DIR)/VoiceFlow.app"

selftest: app   ## Print permission / engine / config status
	$(APP)/Contents/MacOS/VoiceFlow --selftest

clean:
	rm -rf .build build
