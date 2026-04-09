package main

import (
	"io"
	"log"
	"net"
	"sync"

	"github.com/gotd/td/mtproxy/obfuscator"
)

// relay bidirectionally copies data between a TCP client and an obfuscated MTProxy connection.
func relay(client net.Conn, server *obfuscator.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)

	// client → server (raw MTProto → encrypted)
	go func() {
		defer wg.Done()
		n, err := io.Copy(server, client)
		if *verbose && (err != nil || n == 0) {
			log.Printf("[relay-detail] client→server: %d bytes, err=%v", n, err)
		}
	}()

	// server → client (encrypted → raw MTProto)
	go func() {
		defer wg.Done()
		n, err := io.Copy(client, server)
		if *verbose && (err != nil || n == 0) {
			log.Printf("[relay-detail] server→client: %d bytes, err=%v", n, err)
		}
	}()

	wg.Wait()
	client.Close()
	server.Close()
}
