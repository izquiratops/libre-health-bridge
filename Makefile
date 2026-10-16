.PHONY: tools format format-check lint test test-core test-ios

IOS_DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=latest
RESULT_BUNDLE ?= ios/.derivedData/TestResults-$(shell date -u +%Y%m%dT%H%M%SZ).xcresult

# Run once before format, format-check, or lint. Requires the GitHub CLI.
tools:
	bash scripts/install-quality-tools.sh

format:
	.build/quality-tools/swiftformat .

format-check:
	.build/quality-tools/swiftformat . --lint

lint:
	.build/quality-tools/swiftlint lint --strict --no-cache

test: test-core test-ios

test-core:
	swift test --package-path BridgeCore

test-ios:
	xcodebuild test \
		-project LibreHealthBridge.xcodeproj \
		-scheme LibreHealthBridge \
		-destination '$(IOS_DESTINATION)' \
		-parallel-testing-enabled NO \
		-derivedDataPath ios/.derivedData/ci \
		-resultBundlePath '$(RESULT_BUNDLE)' \
		CODE_SIGNING_ALLOWED=NO
