// Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
// SPDX-License-Identifier: GPL-2.0-only
#include "ns3/swarm-hello.h"
#include "ns3/internet-stack-helper.h"
#include "ns3/node-container.h"
#include "ns3/ipv4.h"
#include "ns3/test.h"

#include <array>

using namespace ns3;

class SwarmHelloTestCase : public TestCase {
public:
    SwarmHelloTestCase() : TestCase("LE16 read and a stock-module link") {}

private:
    void DoRun() override {
        const std::array<uint8_t, 2> le{0x34, 0x12};
        uint16_t v = 0;
        NS_TEST_ASSERT_MSG_EQ(SwarmHelloReadLe16(le, v), true, "two bytes must read");
        NS_TEST_ASSERT_MSG_EQ(v, 0x1234, "little-endian order");
        NS_TEST_ASSERT_MSG_EQ(SwarmHelloReadLe16(SwarmHelloBytes(le).first(1), v), false,
                              "short buffer must be refused");

        NodeContainer nodes;
        nodes.Create(2);
        InternetStackHelper stack;
        stack.Install(nodes);
        NS_TEST_ASSERT_MSG_NE(nodes.Get(0)->GetObject<Ipv4>(), nullptr, "internet stack linked");
    }
};

class SwarmHelloTestSuite : public TestSuite {
public:
    SwarmHelloTestSuite() : TestSuite("swarm-hello", Type::UNIT) {
        // Scoped TestCase::Duration arrived in ns-3.42 (3.40/3.41 spell it
        // TestCase::QUICK, and 3.49 dropped that alias). The version comes
        // from CMakeLists.txt; the C++ standard is not a proxy (3.41 builds
        // as C++20 under gcc-13 too).
#if SWARM_HELLO_NS3_MINOR >= 42
        AddTestCase(new SwarmHelloTestCase, TestCase::Duration::QUICK);
#else
        AddTestCase(new SwarmHelloTestCase, TestCase::QUICK);
#endif
    }
};

static SwarmHelloTestSuite g_swarmHelloTestSuite;
