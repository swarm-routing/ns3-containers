# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Quality hook for ns3-build-contrib --strict-warnings / --coverage, loaded
# through CMAKE_PROJECT_INCLUDE. After the whole tree is configured it adds
# options to the named contrib modules' library and test targets only, so no
# stock ns-3 target's compile command changes and the warm cache holds
# (invariant 10; the smoke stage's step-count gate checks it).
#
#   SWARM_CONTRIB_MODULES   ;-list of the contrib modules the options apply to
#                           (their LIBNAME; dependencies built alongside are
#                           left out by ns3-build-contrib --quality-modules)
#   SWARM_STRICT_WARNINGS   ON: strict warnings as errors, except
#                           -Wdeprecated-declarations, which stays a warning
#                           (a dependency's two-step deprecation must not break
#                           a consumer: swarm-routing/ns3-swarm-core
#                           docs/api-policy.md, #167). The generated
#                           include tree (ns-3's and other modules' headers)
#                           is -isystem for these targets, so only the
#                           module's own code is judged; the module's own
#                           headers get non-system ns3/ wrappers searched
#                           first, so `#include "ns3/<own>.h"` stays strict
#   SWARM_COVERAGE          ON: --coverage (gcov) on compile and link
#
# Target names: ns-3.43+ names a module's targets <m> and <m>-test; ns-3.36 to
# 3.42 name them lib<m>, lib<m>-obj (the object library that compiles the
# sources) and lib<m>-test. Every one that exists gets the options.
get_property(_swarm_quality_done GLOBAL PROPERTY SWARM_QUALITY_HOOKED)
if(NOT _swarm_quality_done)
  set_property(GLOBAL PROPERTY SWARM_QUALITY_HOOKED TRUE)
  cmake_language(DEFER DIRECTORY ${CMAKE_SOURCE_DIR} CALL _swarm_quality_apply)
endif()

function(_swarm_quality_apply)
  if(NOT SWARM_STRICT_WARNINGS AND NOT SWARM_COVERAGE)
    return()
  endif()
  set(_gen ${CMAKE_OUTPUT_DIRECTORY}/include ${PROJECT_BINARY_DIR}/include)
  foreach(m IN LISTS SWARM_CONTRIB_MODULES)
    set(_found FALSE)
    if(SWARM_STRICT_WARNINGS)
      # ns-3 exports a module's headers as build/include/ns3/<h> wrappers that
      # are -isystem here; GCC would treat the module's own header as a system
      # header when reached through one. Non-system wrappers for this module's
      # exported headers, searched before the system tree, keep it judged.
      set(_own ${PROJECT_BINARY_DIR}/swarm-quality/${m}/include)
      file(REMOVE_RECURSE ${_own})
      file(GLOB_RECURSE _hdrs
        ${PROJECT_SOURCE_DIR}/contrib/${m}/*.h ${PROJECT_SOURCE_DIR}/contrib/${m}/*.hh
        ${PROJECT_SOURCE_DIR}/contrib/${m}/*.hpp ${PROJECT_SOURCE_DIR}/contrib/${m}/*.hxx)
      foreach(h IN LISTS _hdrs)
        get_filename_component(_name ${h} NAME)
        # Only headers this module exports: ns-3's own ns3/<h> names the
        # header (a one-line #include "<path>" wrapper on 3.40+, a symlink on
        # 3.36-3.39), so a private header that shares a stock header's name
        # (a module-local packet.h) never shadows ns3/packet.h.
        foreach(g IN LISTS _gen)
          if(EXISTS ${g}/ns3/${_name})
            set(_pos -1)
            if(IS_SYMLINK ${g}/ns3/${_name})
              file(REAL_PATH ${g}/ns3/${_name} _target)
              file(REAL_PATH ${h} _real)
              if(_target STREQUAL _real)
                set(_pos 0)
              endif()
            else()
              file(READ ${g}/ns3/${_name} _wrapper)
              string(FIND "${_wrapper}" "${h}" _pos)
            endif()
            if(_pos GREATER -1)
              file(WRITE ${_own}/ns3/${_name} "#include \"${h}\"\n")
              break()
            endif()
          endif()
        endforeach()
      endforeach()
    endif()
    foreach(t ${m} ${m}-test lib${m} lib${m}-obj lib${m}-test)
      if(NOT TARGET ${t})
        continue()
      endif()
      set(_found TRUE)
      if(SWARM_STRICT_WARNINGS)
        target_include_directories(${t} BEFORE PRIVATE ${_own})
        target_include_directories(${t} SYSTEM PRIVATE ${_gen})
        target_compile_options(${t} PRIVATE
          -Wall -Wextra -Wpedantic -Wshadow -Wnon-virtual-dtor -Wold-style-cast
          -Wcast-align -Woverloaded-virtual -Wnull-dereference -Wformat=2 -Werror
          -Wno-error=deprecated-declarations)
      endif()
      if(SWARM_COVERAGE)
        target_compile_options(${t} PRIVATE --coverage)
        target_link_options(${t} PRIVATE --coverage)
      endif()
    endforeach()
    if(NOT _found)
      message(FATAL_ERROR "ns3-build-contrib: no target '${m}' or 'lib${m}' (its build_lib LIBNAME must equal the module name)")
    endif()
  endforeach()
  message(STATUS "ns3-build-contrib: strict-warnings=${SWARM_STRICT_WARNINGS} coverage=${SWARM_COVERAGE} on: ${SWARM_CONTRIB_MODULES}")
endfunction()
