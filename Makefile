.PHONY: build update-lsp-list

# ``make build`` builds the Swift front-end + Mojo dylib + Rust shim and
# assembles them into ``.build/TurboKod.app``. See run_swift.sh for the
# step-by-step. The script also launches the app at the end; pass ``--``
# style env / args via ``./run_swift.sh`` directly when you need that.
build:
	./run_swift.sh

# Refresh src/turbokod/data/languages.json from upstream Helix
# (helix-editor/helix on master). Commit the resulting JSON.
update-lsp-list:
	python3 scripts/refresh_languages.py
