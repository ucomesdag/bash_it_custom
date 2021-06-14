# shellcheck shell=bash

if _command_exists tofu; then
	complete -C /usr/local/bin/tofu tofu
fi
