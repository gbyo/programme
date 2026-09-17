SHELL := /bin/bash

.PHONY: bootstrap doctor generate open test test-ui build format lint lint-all verify verify-fast clean

bootstrap:
	bash scripts/bootstrap.sh

doctor:
	bash scripts/doctor.sh

generate:
	bash scripts/xcodegen.sh generate --spec project.yml

open: generate
	open Programme.xcodeproj

test:
	swift test --package-path Packages/ProgrammeKit

test-ui:
	bash scripts/test-ui.sh

build: generate
	xcodebuild build \
		-project Programme.xcodeproj \
		-scheme Programme \
		-destination 'generic/platform=iOS Simulator' \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO

format:
	bash scripts/format.sh

lint:
	bash scripts/format.sh --check-changed

lint-all:
	bash scripts/format.sh --check

verify:
	bash scripts/verify.sh

verify-fast:
	bash scripts/verify.sh --fast

clean:
	rm -rf Programme.xcodeproj .build Packages/ProgrammeKit/.build build DerivedData
