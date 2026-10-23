#!/bin/bash
# 单元测试统一入口：xcodebuild test（scheme 内含 App 构建一并验证）。
# 推送前强制执行（.githooks/pre-push 调用）；CI 发版构建前也会跑。
# 用法：./scripts/run-tests.sh   （CI 可设 TEST_XCBUILD_FLAGS 附加 xcodebuild 参数）
set -euo pipefail
cd "$(dirname "$0")/.."

# 工程文件不入库，缺失时先生成
if [ ! -d OpenMyApp.xcodeproj ]; then
  xcodegen generate
fi

LOG="$(mktemp -t openmyapp-tests)"
trap 'rm -f "$LOG"' EXIT

# shellcheck disable=SC2086
if xcodebuild -project OpenMyApp.xcodeproj \
  -scheme OpenMyApp \
  -configuration Debug \
  -derivedDataPath build \
  test ${TEST_XCBUILD_FLAGS:-} >"$LOG" 2>&1; then
  grep -E "Test Suite '.*' (passed|failed)" "$LOG" | tail -8
  echo "PASS: all unit tests passed"
else
  grep -E "error:|Test Case.*failed|Failing tests" "$LOG" | head -30
  trap - EXIT
  echo "FAIL: unit tests failed, full log at $LOG"
  exit 1
fi
