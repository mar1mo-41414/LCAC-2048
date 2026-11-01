ARCHS = arm64
TARGET = iphone:clang:latest:13.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
LIBRARY_NAME = Auto2048
Auto2048_FILES = Sources/Controller.m Sources/Engine.m Sources/Solver.c
Auto2048_CFLAGS = -fobjc-arc -Wall -ISources
Auto2048_FRAMEWORKS = UIKit Foundation QuartzCore
Auto2048_LIBRARY_EXTENSION = .dylib
Auto2048_INSTALL_PATH = /usr/lib
include $(THEOS_MAKE_PATH)/library.mk
