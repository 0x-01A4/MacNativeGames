# Source gate for this repository: fast, offline, and it changes no source file.
# It mirrors .github/workflows/tests.yml, so a commit that passes here passes CI.
#
#   make check
#
# The Python tests need the packages in games/totk/requirements.txt; install them once
# (the CI does the same with pip) and this stays offline.

PYTHON ?= python3
CC ?= cc

.PHONY: check

check:
	$(PYTHON) -m unittest discover -s tests -q
	@tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT; \
	 $(CC) -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=all \
	   tests/test_romfs_paths.c -o "$$tmp/test-romfs-paths" && "$$tmp/test-romfs-paths" && \
	 $(CC) -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=all \
	   tests/test_controller_map.c -o "$$tmp/test-controller-map" && "$$tmp/test-controller-map"
