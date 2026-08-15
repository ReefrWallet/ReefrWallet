.DEFAULT_GOAL := all
.PHONY: all project walletkit clean

all: test

project: walletkit
	@echo "==> Generating Xcode project"
	@mise x tuist -- tuist install
	@mise x tuist -- tuist generate --no-open

test:
	$(MAKE) -C WalletKit test
	# @echo "==> Running Swift tests (WalletKitTests)"
	# @mise x tuist -- tuist test --test-targets WalletKitTests

walletkit:
	$(MAKE) -C WalletKit walletkit-ffi

clean:
	$(MAKE) -C WalletKit clean
