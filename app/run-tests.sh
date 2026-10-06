#!/bin/bash
# 金桔测试执行器,两阶段:
#   阶段1 CLI:纯逻辑测试(命名/分类/目录/PDFKit)——裸 CLI 可靠
#   阶段2 App 宿主:进程类引擎测试(sips/LibreOffice/ffmpeg)——与生产同宿主
set -euo pipefail
cd "$(dirname "$0")"

SOURCES=()
for f in Sources/*.swift; do
    [[ "$f" == */main.swift ]] && continue
    SOURCES+=("$f")
done

echo "== 阶段1:纯逻辑测试(CLI) =="
mkdir -p .tests
# shellcheck disable=SC2068
swiftc -O ${SOURCES[@]} Tests/main.swift -o .tests/kumquat-tests 2>/tmp/kq-tests-compile.log
.tests/kumquat-tests

echo "== 阶段2:引擎自测(App 宿主) =="
./build.sh >/dev/null
KUMQUAT_SELF_TEST=1 ./build/Kumquat.app/Contents/MacOS/Kumquat
