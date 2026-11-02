// Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
// SPDX-License-Identifier: GPL-2.0-only
//
// profile-probe: one deliberate behaviour per --mode, so test/profile.sh can
// prove each image profile does what its name says (ns3-containers#41).
//
//   assert     NS_ASSERT(false): aborts where asserts are on (default, debug,
//              sanitized), returns 0 where they are compiled out (optimized)
//   log        NS_LOG_INFO with NS_LOG=ProfileProbe=info: prints where logs are on
//   uaf        heap use after free: ASan must report it (sanitized)
//   leak       an unreferenced heap block at exit: LSan must report it (sanitized)
//   overflow   signed integer overflow: UBSan must report it (sanitized)
//
// The bugs are hidden from the optimizer behind volatile / argv-derived values.

#include "ns3/core-module.h"

#include <climits>
#include <cstdlib>
#include <iostream>
#include <string>

using namespace ns3;

NS_LOG_COMPONENT_DEFINE("ProfileProbe");

static volatile int g_sink = 0;
static int* g_leak = nullptr;

int
main(int argc, char* argv[])
{
    std::string mode;
    CommandLine cmd(__FILE__);
    cmd.AddValue("mode", "assert, log, uaf, leak or overflow", mode);
    cmd.Parse(argc, argv);

    if (mode == "assert")
    {
        volatile bool ok = false;
        NS_ASSERT_MSG(ok, "profile-probe: deliberate assert");
        std::cout << "profile-probe: assert not compiled in" << std::endl;
    }
    else if (mode == "log")
    {
        NS_LOG_INFO("profile-probe: log line");
        std::cout << "profile-probe: log mode done" << std::endl;
    }
    else if (mode == "uaf")
    {
        int* p = new int[4];
        p[0] = argc;
        delete[] p;
        g_sink = p[argc % 4];
    }
    else if (mode == "leak")
    {
        g_leak = new int[64];
        g_leak[0] = argc;
        g_leak = nullptr;
    }
    else if (mode == "overflow")
    {
        volatile int big = INT_MAX;
        int x = big;
        x += argc;
        g_sink = x;
    }
    else
    {
        std::cerr << "profile-probe: unknown --mode=" << mode << std::endl;
        return 2;
    }
    return 0;
}
