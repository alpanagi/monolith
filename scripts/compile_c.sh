#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || $1 != *.c ]]; then
    echo "usage: $0 <file.c>" >&2
    exit 1
fi

mapfile -t files < <(find "$(dirname "$1")" -name '*.c')
gcc -std=c23 -Wall -Wextra -pedantic "${files[@]}" -o "${1%.c}"
