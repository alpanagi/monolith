#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || $1 != *.c ]]; then
    echo "usage: $0 <file.c>" >&2
    exit 1
fi

gcc -std=c23 -Wall -Wextra -pedantic "$1" -o "${1%.c}"
