PLATFORM ?= musl64
STRIP = strip
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
COMPILER ?= ghc9124
EXT = .exe
SYSTEM = windows
else
COMPILER ?= ghc9124
endif
endif
endif

OUT = file-proxy file-proxy-client

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
	nix-shell --run "$(STRIP) -s $@" --argstr compiler-nix-name $(COMPILER) --arg crossPlatforms "ps: with ps; [$(PLATFORM)]"
	chmod -w $@

$(OUT):
	PKG=file-proxy make dist/$(PLATFORM)/$@$(EXT)

package: $(OUT)
	cd dist/$(PLATFORM) && tar cjvf ../file-proxy-$(SYSTEM)-$(PLATFORM).tar.bz2 file-proxy*

dist/bundle/bin/%: bin/%
	@mkdir -p dist/bundle/bin
	@mkdir -p $(BUNDLE_LIB)
	cp $< $@
	nix-shell -p macdylibbundler --run "$(BUNDLE) -x $@"
	echo sudo xattr -d com.apple.quarantine $< >> dist/bundle/install.sh

macos-build:
	stack install --local-bin-path bin

macos-install:
	rm -rf dist/bundle
	@mkdir -p dist/bundle
	echo '#!/usr/bin/env bash' > dist/bundle/install.sh

macos-bundle: macos-install
	$(MAKE) $(BUNDLE_BINS)
	$(MAKE) macos-verify
	cd dist/bundle && find lib -type f | while read F; do echo sudo xattr -d com.apple.quarantine $$F >> install.sh; done
	chmod +x dist/bundle/install.sh
	cd dist/bundle && tar cjvf ../file-proxy-macos-aarch64-bundle.tar.bz2 .

macos-build-bundle: macos-build macos-bundle

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
	@echo make macos-build-bundle
	@echo make macos-static
	@echo make clean
	@echo make update-sha256
