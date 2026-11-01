// Copyright (c) 2026 Daniel Henrique Joppi
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
        NS_TEST_ASSERT_MSG_EQ(SwarmHelloReadLe16(std::span(le).first(1), v), false,
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
        AddTestCase(new SwarmHelloTestCase, TestCase::Duration::QUICK);
    }
};

static SwarmHelloTestSuite g_swarmHelloTestSuite;
