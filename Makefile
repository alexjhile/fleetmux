.PHONY: lint test check

lint:
	shellcheck -x fleetmux setup.sh fleetmux.command lib/*.sh

test:
	bats test/*.bats

check: lint test
