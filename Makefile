#   make                                            check the tools (asks before installing), build and open the Builder
#   make KEYS=~/keys/prod.keys GAME=~/Games/totk.xci   the same, with the Builder's Keys and Game pages filled in
#                                                   (UPDATE=<update.nsp> too); it inspects the game right away
#   make check                                      the source gate below
#
# `make check` is fast, offline, and changes no source file. It mirrors .github/workflows/tests.yml, so a commit that
# passes here passes CI.
#
# The Python tests need the packages in games/totk/requirements.txt; install them once
# (the CI does the same with pip) and this stays offline.

# The tests import compression.zstd (games/totk/scripts/make_romfs_patches.py), which is standard only from Python 3.14;
# the README and the CI use that version, so prefer it when it is installed. PYTHON still overrides this.
PYTHON ?= $(shell command -v python3.14 >/dev/null 2>&1 && echo python3.14 || echo python3)
CC ?= cc

.DEFAULT_GOAL := builder
.PHONY: builder deps check

# The app's path has a space, which make can't use as a target: a stamp stands for it, and goes when the app is gone.
BUILDER_APP := ui/Builder/build/MacNativeGames Builder.app
BUILDER_STAMP := ui/Builder/build/.made
$(shell [ -x "$(BUILDER_APP)/Contents/MacOS/MacNativeGamesBuilder" ] || rm -f $(BUILDER_STAMP))

deps:
	@ui/Builder/setup.sh

$(BUILDER_STAMP): $(wildcard ui/Builder/Sources/*/*.swift) ui/Builder/make_app.sh ui/Builder/swift_sdk.sh
	ui/Builder/make_app.sh
	@touch $@

# The files go to the Builder as if opened in Finder (Wizard.open), which also reaches a Builder that is already open.
builder: deps $(BUILDER_STAMP)
	@set --; for f in "$(KEYS)" "$(GAME)" "$(UPDATE)"; do \
	   [ -n "$$f" ] || continue; \
	   case $$f in "~/"*) f="$$HOME/$${f#\~/}" ;; esac; \
	   [ -e "$$f" ] || { echo "make: no such file: $$f" >&2; exit 1; }; \
	   set -- "$$@" "$$f"; \
	 done; \
	 open -a "$$PWD/$(BUILDER_APP)" "$$@"

check:
	$(PYTHON) -m unittest discover -s tests -q
	@tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT; \
	 $(CC) -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=all \
	   tests/test_romfs_paths.c -o "$$tmp/test-romfs-paths" && "$$tmp/test-romfs-paths" && \
	 $(CC) -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=all \
	   tests/test_controller_map.c -o "$$tmp/test-controller-map" && "$$tmp/test-controller-map"
