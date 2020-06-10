#!/bin/sh
echo "--- run pre deploy script ---"

# echo "create ./tmp/:"
# (mkdir ./tmp && echo "  CREATED") || echo "  alreadey exists?"

echo "copy bs-platform to ./tmp/" &&
cp -rf ./node_modules/bs-platform/* ./tmp-bs-platform/ &&

echo "delete unnecessary files in bs-platform" &&
rm -r ./node_modules/bs-platform/* &&

echo "recreate ./node_modules/bs-platform/lib/js/" &&
mkdir ./node_modules/bs-platform/lib &&
mkdir ./node_modules/bs-platform/lib/js &&

echo "copy bs-platform/lib/js" &&
cp -rf ./tmp-bs-platform/lib/js/* ./node_modules/bs-platform/lib/js/
