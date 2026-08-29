//go:build !linux

package classify

import (
	"context"
	"errors"
	"net"
	"time"
)

// Сырой слой держится на AF_INET/SOCK_RAW и iptables — это Linux. На прочих
// системах пакет собирается, но зонды честно отказываются, а не притворяются.
func rawSupported() bool { return false }

func probePoison(context.Context, net.IP, uint16, Trigger, poison, time.Duration) (bool, error) {
	return false, errors.New("classify: сырые зонды доступны только на Linux")
}

func probeRawHandshake(context.Context, net.IP, uint16, time.Duration) (bool, error) {
	return false, errors.New("classify: сырые зонды доступны только на Linux")
}
