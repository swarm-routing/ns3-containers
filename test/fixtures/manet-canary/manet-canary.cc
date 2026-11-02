// Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
// SPDX-License-Identifier: GPL-2.0-only
//
// manet-canary: a short, sparse ad-hoc MANET run of one stock routing model,
// for the image integration test (ns3-containers#42). Sparse on purpose: a
// small range in a large area keeps the network partitioned part of the
// time, which exercises the "no route" paths (route discovery, request-queue
// drops, ICMP errors) where ns-3.49's AODV livelocks (ns3-containers#35).
//
//   manet-canary --protocol=aodv|olsr|dsdv [--nodes=16] [--area=500]
//                [--range=175] [--pause=120] [--speed=20] [--flows=3]
//                [--time=60] [--seed=1]
//
// Prints one line: `manet-canary: <protocol> sent=<n> received=<n>` and exits
// 0 when the simulation reaches --time. The caller bounds the wall clock.

#include "ns3/aodv-module.h"
#include "ns3/applications-module.h"
#include "ns3/core-module.h"
#include "ns3/dsdv-module.h"
#include "ns3/internet-module.h"
#include "ns3/mobility-module.h"
#include "ns3/network-module.h"
#include "ns3/olsr-module.h"
#include "ns3/wifi-module.h"

#include <iostream>
#include <string>

using namespace ns3;

static uint64_t g_received = 0;

static void
Received(Ptr<const Packet>, const Address&)
{
    ++g_received;
}

int
main(int argc, char* argv[])
{
    std::string protocol = "aodv";
    uint32_t nodes = 16;
    double area = 500;
    double range = 175;
    double pause = 120;
    double speed = 20;
    uint32_t flows = 3;
    double simTime = 60;
    uint32_t seed = 1;
    std::string rate = "64kbps";
    double start = 1.0;

    CommandLine cmd(__FILE__);
    cmd.AddValue("protocol", "aodv, olsr or dsdv", protocol);
    cmd.AddValue("nodes", "number of nodes", nodes);
    cmd.AddValue("area", "side of the square area (m)", area);
    cmd.AddValue("range", "radio range (m)", range);
    cmd.AddValue("pause", "random-waypoint pause (s)", pause);
    cmd.AddValue("speed", "random-waypoint max speed (m/s)", speed);
    cmd.AddValue("flows", "number of CBR flows", flows);
    cmd.AddValue("time", "simulated time (s)", simTime);
    cmd.AddValue("seed", "RngRun", seed);
    cmd.AddValue("rate", "CBR rate per flow (512-byte packets)", rate);
    cmd.AddValue("start", "first flow start (s); flow f starts at start + f", start);
    cmd.Parse(argc, argv);

    RngSeedManager::SetSeed(1);
    RngSeedManager::SetRun(seed);

    NodeContainer n;
    n.Create(nodes);

    WifiHelper wifi;
    wifi.SetStandard(WIFI_STANDARD_80211b);
    wifi.SetRemoteStationManager("ns3::ConstantRateWifiManager",
                                 "DataMode",
                                 StringValue("DsssRate11Mbps"),
                                 "ControlMode",
                                 StringValue("DsssRate1Mbps"));
    YansWifiChannelHelper channel;
    channel.SetPropagationDelay("ns3::ConstantSpeedPropagationDelayModel");
    channel.AddPropagationLoss("ns3::RangePropagationLossModel", "MaxRange", DoubleValue(range));
    YansWifiPhyHelper phy;
    phy.SetChannel(channel.Create());
    WifiMacHelper mac;
    mac.SetType("ns3::AdhocWifiMac");
    NetDeviceContainer dev = wifi.Install(phy, mac, n);

    std::ostringstream side;
    side << "ns3::UniformRandomVariable[Min=0.0|Max=" << area << "]";
    ObjectFactory pos;
    pos.SetTypeId("ns3::RandomRectanglePositionAllocator");
    pos.Set("X", StringValue(side.str()));
    pos.Set("Y", StringValue(side.str()));
    Ptr<PositionAllocator> alloc = pos.Create()->GetObject<PositionAllocator>();
    std::ostringstream spd;
    spd << "ns3::UniformRandomVariable[Min=0.0|Max=" << speed << "]";
    std::ostringstream pse;
    pse << "ns3::ConstantRandomVariable[Constant=" << pause << "]";
    MobilityHelper mobility;
    mobility.SetMobilityModel("ns3::RandomWaypointMobilityModel",
                              "Speed",
                              StringValue(spd.str()),
                              "Pause",
                              StringValue(pse.str()),
                              "PositionAllocator",
                              PointerValue(alloc));
    mobility.SetPositionAllocator(alloc);
    mobility.Install(n);

    InternetStackHelper stack;
    if (protocol == "aodv")
    {
        stack.SetRoutingHelper(AodvHelper());
    }
    else if (protocol == "olsr")
    {
        stack.SetRoutingHelper(OlsrHelper());
    }
    else if (protocol == "dsdv")
    {
        stack.SetRoutingHelper(DsdvHelper());
    }
    else
    {
        std::cerr << "manet-canary: unknown protocol " << protocol << std::endl;
        return 2;
    }
    stack.Install(n);
    Ipv4AddressHelper ip;
    ip.SetBase("10.1.0.0", "255.255.0.0");
    Ipv4InterfaceContainer ifs = ip.Assign(dev);

    const uint16_t port = 9;
    for (uint32_t f = 0; f < flows && 2 * f + 1 < nodes; ++f)
    {
        uint32_t src = 2 * f;
        uint32_t dst = 2 * f + 1;
        PacketSinkHelper sink("ns3::UdpSocketFactory",
                              InetSocketAddress(Ipv4Address::GetAny(), port));
        ApplicationContainer s = sink.Install(n.Get(dst));
        s.Get(0)->TraceConnectWithoutContext("Rx", MakeCallback(&Received));
        OnOffHelper onoff("ns3::UdpSocketFactory", InetSocketAddress(ifs.GetAddress(dst), port));
        onoff.SetConstantRate(DataRate(rate), 512);
        ApplicationContainer a = onoff.Install(n.Get(src));
        a.Start(Seconds(start + f));
        a.Stop(Seconds(simTime));
    }

    Simulator::Stop(Seconds(simTime));
    Simulator::Run();
    Simulator::Destroy();
    std::cout << "manet-canary: " << protocol << " received=" << g_received
              << std::endl;
    return 0;
}
