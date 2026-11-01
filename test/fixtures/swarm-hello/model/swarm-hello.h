// Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
// SPDX-License-Identifier: GPL-2.0-only
#ifndef SWARM_HELLO_H
#define SWARM_HELLO_H

#include <cstdint>
#include <span>

namespace ns3 {

/// Little-endian 16-bit read from a bounds-checked span (C++20 std::span).
/// Returns false when fewer than two bytes remain.
bool SwarmHelloReadLe16(std::span<const uint8_t> buf, uint16_t& out);

}  // namespace ns3

#endif  // SWARM_HELLO_H
