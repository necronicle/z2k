package main

import (
	"io"
	"sync"
)

// relay bidirectionally copies data between two connections.
// Closes both when either direction finishes.
func relay(a io.ReadWriteCloser, b io.ReadWriteCloser) {
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		io.Copy(b, a)
		// Signal the other side to stop
		if closer, ok := b.(interface{ CloseWrite() error }); ok {
			closer.CloseWrite()
		}
	}()

	go func() {
		defer wg.Done()
		io.Copy(a, b)
		if closer, ok := a.(interface{ CloseWrite() error }); ok {
			closer.CloseWrite()
		}
	}()

	wg.Wait()
	a.Close()
	b.Close()
}
