.DEFAULT_GOAL := all
.PHONY: all project walletkit clean

all: test

clean:
	$(MAKE) -C WalletKit clean
	@tuist clean
	@rm -rf Derived *.xcodeproj *.xcworkspace

project: Tuist/ProjectDescriptionHelpers/Project+Version.swift WalletKit/Frameworks/WalletKit.xcframework
	@echo "==> Generating Xcode project"
	@mise x tuist -- tuist install
	@mise x tuist -- tuist generate --no-open

test: ReefrWallet.xcworkspace
	@echo "==> Running Rust tests
	$(MAKE) -C WalletKit test

	@echo "==> Running Swift tests
	@mise x tuist -- tuist test --test-targets WalletKitTests-macOS

versions:
	Scripts/make_versions.sh

walletkit:
	$(MAKE) -C WalletKit sui-grpc walletkit-ffi

ReefrWallet.xcworkspace: project
Tuist/ProjectDescriptionHelpers/Project+Version.swift: versions
WalletKit/Frameworks/WalletKit.xcframework: walletkit
