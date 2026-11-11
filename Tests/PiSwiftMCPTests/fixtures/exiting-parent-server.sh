#!/bin/sh
sleep 30 &
echo "helper $!" >&2
exit 0
