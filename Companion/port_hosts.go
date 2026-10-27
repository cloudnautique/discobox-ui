package main

import "github.com/discobox-ai/discobox/cli/internal/portforward"

// Bind-address handling follows the CLI listening_ports.go implementation.
func dialHostForPort(addresses []string, network portforward.Network) string {
	if network == portforward.UDP {
		return udpDialHost(addresses)
	}
	for _, address := range addresses {
		switch address {
		case "0.0.0.0", "::", "[::]", "*", "127.0.0.1", "::1", "[::1]", "localhost":
			return portforward.DefaultDialHost
		}
	}
	for _, address := range addresses {
		if address != "" {
			return address
		}
	}
	return portforward.DefaultDialHost
}

// udpDialLoopback is where a UDP port with nothing better to go on is dialed:
// IPv4 loopback, which a wildcard IPv6 socket that is not v6-only answers too.
const udpDialLoopback = "127.0.0.1"

// udpDialHost is dialHostForPort for a UDP port: IPv4 loopback for an IPv4
// wildcard or loopback bind, IPv6 loopback for an IPv6-only one, and the
// address itself for anything else. A declared port with no address is dialed
// at IPv4 loopback, as the sandbox's own probe would be.
func udpDialHost(addresses []string) string {
	var v6Loopback bool
	for _, address := range addresses {
		switch address {
		case "0.0.0.0", "127.0.0.1":
			return udpDialLoopback
		case "::", "[::]", "::1", "[::1]":
			v6Loopback = true
		}
	}
	if v6Loopback {
		return "::1"
	}
	for _, address := range addresses {
		if address != "" {
			return address
		}
	}
	return udpDialLoopback
}
