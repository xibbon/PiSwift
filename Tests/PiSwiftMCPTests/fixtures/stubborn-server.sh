#!/bin/sh
trap '' TERM
sleep 30 &
echo "grandchild:$!" >&2
while :; do sleep 1; done
