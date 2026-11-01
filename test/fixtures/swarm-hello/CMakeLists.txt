# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: GPL-2.0-only
#
# Smoke fixture: the smallest contrib module that exercises what downstream
# repos need from the image (a library linked against stock modules, std::span
# on C++20+ trees with a C++17 fallback for ns-3.40, and a test suite run
# by test.py).
# ns-3 renamed TestCase durations in 3.42 (TestCase::QUICK -> Duration::QUICK)
# and dropped the old alias in 3.49; the test picks by ns-3 minor version.
string(REGEX MATCH "^3\\.([0-9]+)" _swarm_hello_ver "${NS3_VER}")
add_compile_definitions(SWARM_HELLO_NS3_MINOR=${CMAKE_MATCH_1})

build_lib(
  LIBNAME swarm-hello
  SOURCE_FILES model/swarm-hello.cc
  HEADER_FILES model/swarm-hello.h
  LIBRARIES_TO_LINK ${libinternet}
  TEST_SOURCES test/swarm-hello-test-suite.cc
)
