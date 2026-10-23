# Windows 95 build 950: TCP/IP Winsock registration

The installed RTM automatic-PnP path lost its pre-GUI TCP/IP classes.
R111 compared closed hives and found seventeen missing NET95 entries.
The reader matched an entire display subtree exported by the original
DOS REGEDIT in R109 and the VNETSUP export from R101.

On a new overlay of the installed R110 base, R112 reapplied NET95 after
GUI Setup. R114 then obtained an actual DHCP lease, 10.0.2.15, with router
10.0.2.2 and DNS 10.0.2.3. The completed NETPROBE still returned mask24:
DNS error11004 and ICMP error10043. The closed64-packet capture contained
the correlated DHCP request/ACK, but no successful echo or DNS pair.
This was a network-only test; successful USB and restart tests were not
repeated, and no Windows Setup was started.

The failed hive lacked MSTCP's Winsock helper/provider registration.
The working R85 reference contained it. The original target's
NETTRANS.INF MSTCP.AddReg confirms these are separate machine settings,
in addition to the class-relative entries NET95 already supplies.

The 950 static-NET95 writer now generates NET/TCP95.REG and includes it
in REG95.REG. It registers AFVXD/WSHTCP, address sizes, the TCP provider,
resolver priorities, provider order, RPC transports and the Winsock DLL
version-check entry. The companion can also be imported into an installed
overlay without repeating Setup. It does not edit NET95.REG, choose an
address, change DNS policy, replace an inbox binary or add network
components. Other source versions and configurations without static
NET95 retain their existing behavior.

Validation: five new host tests and thirty-six existing regression tests
passed. R116 independently compared all ten generated machine keys and
sixteen typed values to the original RTM MSTCP.AddReg globals in memory:
exact agreement. Raw Microsoft INF/registry payloads remain in private
VM storage. The production TCP95 runtime test and the separate post-GUI
timing change are still pending; this commit alone is not a network PASS.

The installed R115 overlay and matching-DOS import script are prepared
but have not run while the OSR1 agent owns both reserved QEMU engines.
No full release build, merge, push, deployment, hub or NT4 USB change.
