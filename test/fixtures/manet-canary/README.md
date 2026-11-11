# manet-canary

A short ad-hoc MANET simulation of one stock routing model (`aodv`, `olsr`,
`dsdv`), built from the image's ns-3 tree by `test/integration.sh`
(ns3-containers#42). Written against public ns-3 APIs only; it contains no
code from ns-3's own examples.

Two scenarios are run per protocol:

- **dense** (`--range=175`): must finish within its budget and deliver
  packets;
- **sparse** (`--range=100`): the network is partitioned much of the time, so
  route discovery fails and AODV's request queue drops packets. It must
  finish within its budget. On ns-3.49 stock AODV never finishes this run:
  `Ipv4L3Protocol::SendIcmpNoRoute` feeds back into AODV's deferred route
  output in zero simulated time (ns3-containers#35,
  swarm-routing/AntHocNet#843).
