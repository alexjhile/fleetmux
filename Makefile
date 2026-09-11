.PHONY: lint test check

lint:
	shellcheck -x fleetmux lib/*.sh

test:
	bats test/*.bats

check: lint test
