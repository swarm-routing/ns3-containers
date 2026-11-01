// Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
// SPDX-License-Identifier: GPL-2.0-only
#ifndef SWARM_HELLO_H
#define SWARM_HELLO_H

#include <cstddef>
#include <cstdint>

#if __cplusplus >= 202002L
#include <span>
#endif

namespace ns3 {

#if __cplusplus >= 202002L
/// A bounds-checked byte view: std::span on C++20 trees (ns-3.42 and later).
using SwarmHelloBytes = std::span<const uint8_t>;
#else
/// The same view on C++17 trees (ns-3.40, 3.41), which have no std::span.
class SwarmHelloBytes {
public:
    template <typename C>
    SwarmHelloBytes(const C& c) : m_data(c.data()), m_size(c.size()) {}
    SwarmHelloBytes(const uint8_t* data, std::size_t size) : m_data(data), m_size(size) {}
    std::size_t size() const { return m_size; }
    uint8_t operator[](std::size_t i) const { return m_data[i]; }
    SwarmHelloBytes first(std::size_t n) const { return {m_data, n < m_size ? n : m_size}; }

private:
    const uint8_t* m_data;
    std::size_t m_size;
};
#endif

/// Little-endian 16-bit read from a bounds-checked view.
/// Returns false when fewer than two bytes remain.
bool SwarmHelloReadLe16(SwarmHelloBytes buf, uint16_t& out);

}  // namespace ns3

#endif  // SWARM_HELLO_H
