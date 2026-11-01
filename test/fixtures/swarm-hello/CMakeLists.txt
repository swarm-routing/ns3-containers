# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: GPL-2.0-only
#
# Smoke fixture: the smallest contrib module that exercises what downstream
# repos need from the image (a library linked against stock modules, a C++20
# feature, and a test suite run by test.py).
build_lib(
  LIBNAME swarm-hello
  SOURCE_FILES model/swarm-hello.cc
  HEADER_FILES model/swarm-hello.h
  LIBRARIES_TO_LINK ${libinternet}
  TEST_SOURCES test/swarm-hello-test-suite.cc
)
