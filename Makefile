.DEFAULT_GOAL := all
.PHONY: all project walletkit clean

all: test

clean:
	$(MAKE) -C WalletKit clean
	@tuist clean

project: Tuist/ProjectDescriptionHelpers/Project+Version.swift WalletKit/Frameworks/WalletKit.xcframework
	@echo "==> Generating Xcode project"
	@mise x tuist -- tuist install
	@mise x tuist -- tuist generate --no-open

test:
	@echo "==> Running Rust tests (walletkit-ffi)"
	$(MAKE) -C WalletKit test

	@echo "==> Running Swift tests (WalletKit)"
	@mise x tuist -- tuist test --test-targets WalletKitTests

versions:
	Scripts/make_versions.sh

walletkit:
	$(MAKE) -C WalletKit walletkit-ffi

ReefrWallet.xcworkspace: project
Tuist/ProjectDescriptionHelpers/Project+Version.swift: versions
WalletKit/Frameworks/WalletKit.xcframework: walletkit
