#!/bin/bash


VER=`git rev-parse --short HEAD`
RELFILE="release-${VER}.tar"
echo $VER > version
tar -rf ${RELFILE} version
find ./ -name ebin -type d -exec tar -rf ${RELFILE} {} ';'
find ./ -name priv -type d -exec tar -rf ${RELFILE} {} ';'
tar -rf ${RELFILE} scripts utils
gzip -9 ${RELFILE}
