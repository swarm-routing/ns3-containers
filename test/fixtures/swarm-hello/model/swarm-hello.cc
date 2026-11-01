// Copyright (c) 2026 Daniel Henrique Joppi
// SPDX-License-Identifier: GPL-2.0-only
#include "swarm-hello.h"

namespace ns3 {

bool SwarmHelloReadLe16(std::span<const uint8_t> buf, uint16_t& out) {
    if (buf.size() < 2) return false;
    out = static_cast<uint16_t>(buf[0] | (buf[1] << 8));
    return true;
}

}  // namespace ns3
