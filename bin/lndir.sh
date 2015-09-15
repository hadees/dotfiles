#!/bin/bash
oldifs=$IFS
IFS='
'
[ $# -ne 2 ] && { echo "Usage: $0 sourceDirectory destinationDirectory" ; exit 1; }
[ ! -d "$1" ] && { echo "$1 is not a valid directory"; exit 1; }
[ ! -d "$2" ] && { mkdir -p "$2"; }
src=$(cd "$1" ; pwd)
dst=$(cd "$2" ; pwd)
find "$src" -type d |
while read dir; do
        mkdir -p "$dst${dir#$src}"
done

find "$src" -type f -o -type l |
while read src_f; do
        dst_f="$dst${src_f#$src}"
        ln "$src_f" "$dst_f"
done
IFS=$oldifs
