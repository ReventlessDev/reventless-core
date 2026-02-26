#!/bin/sh
echo "--- run post deploy script ---"

echo "copy bs-platform back to node_modules" &&
cp -rf ./tmp-bs-platform/* ./node_modules/bs-platform/
