// Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
// SPDX-License-Identifier: MIT
#include "swarm-hello.h"

namespace ns3 {

bool SwarmHelloReadLe16(std::span<const uint8_t> buf, uint16_t& out) {
    if (buf.size() < 2) return false;
    out = static_cast<uint16_t>(buf[0] | (buf[1] << 8));
    return true;
}

}  // namespace ns3
