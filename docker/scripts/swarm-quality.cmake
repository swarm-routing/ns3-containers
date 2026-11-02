# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Quality hook for ns3-build-contrib --strict-warnings / --coverage, loaded
# through CMAKE_PROJECT_INCLUDE. After the whole tree is configured it adds
# options to the named contrib modules' library and test targets only, so no
# stock ns-3 target's compile command changes and the warm cache holds
# (invariant 10; the smoke stage's step-count gate checks it).
#
#   SWARM_CONTRIB_MODULES   ;-list of contrib module names (their LIBNAME)
#   SWARM_STRICT_WARNINGS   ON: strict warnings as errors; ns-3's headers are
#                           made -isystem for these targets, so only the
#                           module's own code is judged
#   SWARM_COVERAGE          ON: --coverage (gcov) on compile and link
get_property(_swarm_quality_done GLOBAL PROPERTY SWARM_QUALITY_HOOKED)
if(NOT _swarm_quality_done)
  set_property(GLOBAL PROPERTY SWARM_QUALITY_HOOKED TRUE)
  cmake_language(DEFER DIRECTORY ${CMAKE_SOURCE_DIR} CALL _swarm_quality_apply)
endif()

function(_swarm_quality_apply)
  if(NOT SWARM_STRICT_WARNINGS AND NOT SWARM_COVERAGE)
    return()
  endif()
  foreach(m IN LISTS SWARM_CONTRIB_MODULES)
    set(_found FALSE)
    foreach(t ${m} ${m}-test)
      if(NOT TARGET ${t})
        continue()
      endif()
      set(_found TRUE)
      if(SWARM_STRICT_WARNINGS)
        target_include_directories(${t} SYSTEM PRIVATE
          ${CMAKE_OUTPUT_DIRECTORY}/include ${PROJECT_BINARY_DIR}/include)
        target_compile_options(${t} PRIVATE
          -Wall -Wextra -Wpedantic -Wshadow -Wnon-virtual-dtor -Wold-style-cast
          -Wcast-align -Woverloaded-virtual -Wnull-dereference -Wformat=2 -Werror)
      endif()
      if(SWARM_COVERAGE)
        target_compile_options(${t} PRIVATE --coverage)
        target_link_options(${t} PRIVATE --coverage)
      endif()
    endforeach()
    if(NOT _found)
      message(FATAL_ERROR "ns3-build-contrib: no target '${m}' (its build_lib LIBNAME must equal the module name)")
    endif()
  endforeach()
  message(STATUS "ns3-build-contrib: strict-warnings=${SWARM_STRICT_WARNINGS} coverage=${SWARM_COVERAGE} on: ${SWARM_CONTRIB_MODULES}")
endfunction()
