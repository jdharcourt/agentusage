.PHONY: build test run clean

build:
	bash scripts/build.sh

test:
	swift test

run: build
	open dist/AgentUsage.app

clean:
	swift package clean
