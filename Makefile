# Auto2048 — LiveContainer 用 2048 自走 tweak
#
# ビルドには Theos と iOS SDK が必要 (https://theos.dev)。
#   make FINALPACKAGE=1   -> .theos/obj/ に Auto2048.dylib
#
# ホスト側のテストは Theos が無くても動く。
#   make test             -> 単体テスト + 10,000 盤面の移動処理比較
#   make simulate         -> 簡易シミュレーション (既定 3 ゲーム × 5,000 手)

ARCHS = arm64
TARGET = iphone:clang:latest:13.0
THEOS_PACKAGE_SCHEME = rootless

THEOS_COMMON := $(THEOS)/makefiles/common.mk

ifeq ($(wildcard $(THEOS_COMMON)),)
$(warning THEOS が設定されていません。ビルドはできません (テストのみ: make test)。)
else
include $(THEOS_COMMON)

LIBRARY_NAME = Auto2048
Auto2048_FILES = Sources/Controller.m Sources/Engine.m Sources/Solver.c
Auto2048_CFLAGS = -fobjc-arc -Wall -ISources
Auto2048_FRAMEWORKS = UIKit Foundation QuartzCore
Auto2048_LIBRARY_EXTENSION = .dylib
Auto2048_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
endif

# --- テスト (ホスト側。Theos 不要) -----------------------------------------

CC ?= cc
TEST_CFLAGS ?= -O2 -Wall -Wextra
BUILD_DIR = build

SIM_GAMES ?= 3
SIM_MOVES ?= 5000
SIM_SPAWN ?= 0
# 出現位置: uniform (空きマスから等確率) / measured (実機の実測分布)
SIM_ENV ?= uniform
# ソルバーに渡す出現位置の仮定: uniform / measured
SIM_MODEL ?= uniform

ifeq ($(wildcard $(THEOS_COMMON)),)
all:
	@echo "Theos が見つかりません。THEOS=/path/to/theos を設定してください (テストだけなら make test)。"
endif

.PHONY: test test-solver test-internal simulate clean-test

test: test-solver test-internal

test-solver: $(BUILD_DIR)/solver_test
	./$(BUILD_DIR)/solver_test

test-internal: $(BUILD_DIR)/internal_test
	./$(BUILD_DIR)/internal_test

simulate: $(BUILD_DIR)/simulate
	./$(BUILD_DIR)/simulate $(SIM_GAMES) $(SIM_MOVES) $(SIM_SPAWN) $(SIM_ENV) $(SIM_MODEL)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# solver_test / simulate は Solver.c を別途コンパイルしてリンクする。
$(BUILD_DIR)/solver_test: tests/solver_test.c Sources/Solver.c Sources/Solver.h | $(BUILD_DIR)
	$(CC) $(TEST_CFLAGS) -ISources tests/solver_test.c Sources/Solver.c -lm -o $@

$(BUILD_DIR)/simulate: tests/simulate.c Sources/Solver.c Sources/Solver.h Sources/SpawnBias.h | $(BUILD_DIR)
	$(CC) $(TEST_CFLAGS) -ISources tests/simulate.c Sources/Solver.c -lm -o $@

# internal_test は Solver.c を include するので、テストファイルだけをコンパイルする。
$(BUILD_DIR)/internal_test: tests/internal_test.c Sources/Solver.c | $(BUILD_DIR)
	$(CC) $(TEST_CFLAGS) -ISources tests/internal_test.c -lm -o $@

clean-test:
	rm -rf $(BUILD_DIR)
