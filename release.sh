#!/usr/bin/env bash

VERSION=v1.2.0.0

make macos-static

cd dist

rsync -avz sens:/data/src/file-proxy/dist/*.tar.bz2 .

mv file-proxy-linux-musl64.tar.bz2 file-proxy-linux-$VERSION.tar.bz2
mv file-proxy-linux-aarch64-multiplatform-musl.tar.bz2 file-proxy-linux-aarch64-$VERSION.tar.bz2
mv file-proxy-windows-mingwW64.tar.bz2 file-proxy-windows-$VERSION.tar.bz2
mv file-proxy-macos-aarch64-bundle.tar.bz2 file-proxy-macos-aarch64-$VERSION.tar.bz2
