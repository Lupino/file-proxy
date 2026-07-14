PLATFORM ?= musl64
STRIP = strip
OBJDUMP = objdump
NIX_CROSS_SHELL = nix-shell --argstr compiler-nix-name $(COMPILER) --arg crossPlatforms "ps: with ps; [$(PLATFORM)]"
PKG ?= file-proxy
SYSTEM = linux
EXT =

ifeq ($(PLATFORM),aarch64-multiplatform-musl)
STRIP = aarch64-linux-gnu-strip
COMPILER ?= ghc9124
else
ifeq ($(PLATFORM),muslpi)
STRIP = armv6l-unknown-linux-musleabihf-strip
COMPILER ?= ghc884
else
ifeq ($(PLATFORM),mingwW64)
STRIP = x86_64-w64-mingw32-strip
OBJDUMP = x86_64-w64-mingw32-objdump
COMPILER ?= ghc9124
EXT = .exe
SYSTEM = windows
else
COMPILER ?= ghc9124
endif
endif
endif

OUT = file-proxy file-proxy-client file-proxy-web
WEB_ASSETS_GENERATOR = web-assets/generate-web-assets.js
WEB_ASSETS_MODULE = web-assets/src/FileProxy/WebAssets.hs

BUNDLE_BIN = dist/bundle/bin
BUNDLE_LIB = dist/bundle/lib/file-proxy
BUNDLE_EXEC_PATH = @executable_path/../lib/file-proxy
BUNDLE = dylibbundler -b -d $(BUNDLE_LIB) -p '$(BUNDLE_EXEC_PATH)' -of
BUNDLE_BINS = $(foreach var,$(OUT),dist/bundle/bin/$(var))

all: package

dist/$(PLATFORM):
	mkdir -p $@

dist/$(PLATFORM)/%: dist/$(PLATFORM)
	nix-build -A projectCross.$(PLATFORM).hsPkgs.$(PKG).components.exes.$(shell basename $@ $(EXT)) --argstr compiler-nix-name $(COMPILER) # --arg enableProfiling true
	cp -f result/bin/$(shell basename $@) $@
	chmod +w $@
	$(NIX_CROSS_SHELL) --run "$(STRIP) -s $@"
	@if [ "$(SYSTEM)" = "windows" ]; then \
		closure="$$(nix-store -qR result)"; \
		$(NIX_CROSS_SHELL) --run "$(OBJDUMP) -p $@" | awk '/DLL Name:/ {print $$3}' | while read DLL; do \
			DLL_PATH="$$(find $$closure -type f -iname "$$DLL" -print -quit)"; \
			if [ -n "$$DLL_PATH" ]; then \
				cp -f "$$DLL_PATH" dist/$(PLATFORM)/; \
			fi; \
		done; \
	fi
	chmod -w $@

$(OUT):
	PKG=file-proxy make dist/$(PLATFORM)/$@$(EXT)

package: $(OUT)
	@if [ "$(SYSTEM)" = "windows" ]; then $(MAKE) windows-verify; fi
	@if [ "$(SYSTEM)" = "windows" ]; then \
		cd dist/$(PLATFORM) && tar cjvf ../file-proxy-$(SYSTEM)-$(PLATFORM).tar.bz2 *; \
	else \
		cd dist/$(PLATFORM) && tar cjvf ../file-proxy-$(SYSTEM)-$(PLATFORM).tar.bz2 file-proxy*; \
	fi

web-assets-refresh:
	cd web-assets && npm run build

check-web-assets:
	@tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	node $(WEB_ASSETS_GENERATOR) --output "$$tmp"; \
	if ! cmp -s "$$tmp" "$(WEB_ASSETS_MODULE)"; then \
		diff -u "$(WEB_ASSETS_MODULE)" "$$tmp"; \
		echo "error: embedded web assets are stale; run make web-assets-refresh" >&2; \
		exit 1; \
	fi

macos-build:
	stack install --local-bin-path $(BUNDLE_BIN)
	@mkdir -p $(BUNDLE_LIB)
	@for F in $(BUNDLE_BINS); do \
		nix-shell -p macdylibbundler --run "$(BUNDLE) -x $$F"; \
		echo sudo xattr -d com.apple.quarantine $$F >> dist/bundle/install.sh; \
	done

macos-install:
	rm -rf dist/bundle
	@mkdir -p dist/bundle
	echo '#!/usr/bin/env bash' > dist/bundle/install.sh

macos-bundle: macos-install macos-build
	$(MAKE) $(BUNDLE_BINS)
	$(MAKE) macos-verify
	cd dist/bundle && find lib -type f | while read F; do echo sudo xattr -d com.apple.quarantine $$F >> install.sh; done
	chmod +x dist/bundle/install.sh
	cd dist/bundle && tar cjvf ../file-proxy-macos-aarch64-bundle.tar.bz2 .

macos-static: macos-bundle

macos-verify:
	@set -e; \
	for F in $(BUNDLE_BINS); do \
		echo "Checking $$F"; \
		otool -L "$$F"; \
		if otool -L "$$F" | grep -q '/nix/store'; then \
			echo "error: $$F still links against /nix/store" >&2; \
			exit 1; \
		fi; \
		done

windows-verify:
	@set -e; \
	for F in $(foreach var,$(OUT),dist/$(PLATFORM)/$(var)$(EXT)); do \
		echo "Checking $$F"; \
		$(NIX_CROSS_SHELL) --run "$(OBJDUMP) -p $$F" | awk '/DLL Name:/ {print $$3}' | while read DLL; do \
			UPPER="$$(printf '%s' "$$DLL" | tr '[:lower:]' '[:upper:]')"; \
			case "$$UPPER" in \
				API-MS-WIN-*|ADVAPI32.DLL|DBGHELP.DLL|GDI32.DLL|KERNEL32.DLL|MSVCRT.DLL|NTDLL.DLL|OLE32.DLL|RPCRT4.DLL|SHELL32.DLL|USER32.DLL|WINMM.DLL|WS2_32.DLL) \
					;; \
				*) \
					if [ ! -f "dist/$(PLATFORM)/$$DLL" ]; then \
						echo "error: $$F imports $$DLL but it is missing from dist/$(PLATFORM)" >&2; \
						exit 1; \
					fi; \
					;; \
			esac; \
		done; \
	done

update-sha256:
	gawk -f nix/update-sha256.awk cabal.project > nix/sha256map.nix

clean:
	rm -rf dist

help:
	@echo make PLATFORM=muslpi
	@echo make PLATFORM=musl64
	@echo make PLATFORM=aarch64-multiplatform-musl
	@echo make PLATFORM=mingwW64
	@echo make macos-bundle
	@echo make macos-static
	@echo make web-assets-refresh
	@echo make check-web-assets
	@echo make clean
	@echo make update-sha256
