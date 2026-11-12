#!/bin/bash

# lndir.sh — mirror a directory tree with hard links (not symlinks), creating
# the directories as real ones. Exits 1 if any mkdir or ln failed.
# Usage: lndir.sh sourceDirectory destinationDirectory

oldifs=$IFS
IFS='
'
[ $# -ne 2 ] && { echo "Usage: $0 sourceDirectory destinationDirectory" ; exit 1; }
[ ! -d "$1" ] && { echo "$1 is not a valid directory"; exit 1; }
[ ! -d "$2" ] && { mkdir -p "$2"; }
src=$(cd "$1" && pwd) || { echo "cannot resolve $1"; exit 1; }
dst=$(cd "$2" && pwd) || { echo "cannot resolve $2"; exit 1; }
# Both loops run on the far side of a pipe, so each carries its status out
# in a brace group's exit.
find "$src" -type d |
{
        rc=0
        while read -r dir; do
                mkdir -p "$dst${dir#"$src"}" || rc=1
        done
        exit $rc
} || failed=1

find "$src" -type f -o -type l |
{
        rc=0
        while read -r src_f; do
                dst_f="$dst${src_f#"$src"}"
                ln "$src_f" "$dst_f" || rc=1
        done
        exit $rc
} || failed=1
IFS=$oldifs
exit ${failed:-0}
