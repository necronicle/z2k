//go:build !linux

package domainroute

import (
	"context"
	"errors"
)

func receivePackets(context.Context, func([]byte), func(error)) (func(), error) {
	return nil, errors.New("DNS capture requires Linux")
}
