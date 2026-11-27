.PHONY: app check icon run install uninstall selftest clean

APP := build/Airflow.app
INSTALL_DIR := $(HOME)/Applications

app:            ## Build build/Airflow.app
	./scripts/build-app.sh

icon:           ## Regenerate Resources/AppIcon.icns and the menu-bar glyph
	swift scripts/make-icon.swift

check:          ## Run the unit checks
	swift run airflow-checks

run: app        ## Build and launch from build/
	open $(APP)

install: app    ## Install to ~/Applications and launch
	-pkill -x Airflow
	rm -rf "$(INSTALL_DIR)/Airflow.app"
	mkdir -p "$(INSTALL_DIR)"
	cp -R $(APP) "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/Airflow.app"

uninstall:
	-pkill -x Airflow
	rm -rf "$(INSTALL_DIR)/Airflow.app"

selftest: app   ## Print permission / engine / config status
	$(APP)/Contents/MacOS/Airflow --selftest

clean:
	rm -rf .build build
