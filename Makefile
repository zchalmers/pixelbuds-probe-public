SHELL := /bin/bash

generate:
	xcodegen generate

# Syntax only. No Apple SDK here, so this catches parse errors and nothing else.
parse:
	swiftc -parse App/*.swift

lint:
	.swiftlint 2>/dev/null || true

clean:
	rm -rf .build exports/*.ipa

.PHONY: generate parse lint clean
