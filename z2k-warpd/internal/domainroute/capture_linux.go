//go:build linux

package domainroute

import (
	"context"
	"errors"
	"sync"

	"github.com/florianl/go-nflog/v2"
	"github.com/florianl/go-nfqueue/v2"
)

// Номер очереди ответов DNS совпадает с группой NFLOG их копий. Копии
// слушаем по-прежнему: правила ставит скрипт, и до его обновления (или на
// ядре без NFQUEUE) ответы приходят копией — без придерживания, как раньше.
const dnsGroup = 189

func receivePackets(ctx context.Context, handle func([]byte), onError func(error)) (func(), error) {
	h := newHolder(handle, holdMax, holdQueueLen)
	// Свой контекст, не ctx наблюдателя: библиотека по отмене отвязывает
	// очередь, и ядро сбрасывает придержанные ответы. Сначала отпускаем их.
	own, cancel := context.WithCancel(context.Background())
	report := func(e error) int {
		if !errors.Is(e, context.Canceled) && own.Err() == nil {
			onError(e)
		}
		return 0
	}
	q, qerr := openQueue(own, h, report)
	l, lerr := openLog(own, h, report)
	if qerr != nil && lerr != nil {
		cancel()
		h.stop()
		return nil, errors.Join(qerr, lerr)
	}
	return func() {
		h.stop()
		cancel()
		if q != nil {
			_ = q.Close()
		}
		if l != nil {
			_ = l.Close()
		}
	}, nil
}

func openQueue(ctx context.Context, h *holder, report func(error) int) (*nfqueue.Nfqueue, error) {
	cfg := nfqueue.Config{NfQueue: dnsGroup, MaxPacketLen: 4096, MaxQueueLen: holdQueueLen,
		Copymode: nfqueue.NfQnlCopyPacket, Flags: nfqueue.NfQaCfgFlagFailOpen}
	q, err := registerQueue(ctx, cfg, h, report)
	if err != nil {
		// Ядро без fail-open: при переполнении очереди ответы теряются, но
		// дольше holdMax мы их всё равно не держим.
		cfg.Flags = 0
		q, err = registerQueue(ctx, cfg, h, report)
	}
	return q, err
}

func registerQueue(ctx context.Context, cfg nfqueue.Config, h *holder, report func(error) int) (*nfqueue.Nfqueue, error) {
	q, err := nfqueue.Open(&cfg)
	if err != nil {
		return nil, err
	}
	var verdict sync.Mutex
	if err := q.RegisterWithErrorFunc(ctx, func(a nfqueue.Attribute) int {
		if a.PacketID == nil {
			return 0
		}
		id := *a.PacketID
		var packet []byte
		if a.Payload != nil {
			packet = append([]byte(nil), *a.Payload...)
		}
		h.push(packet, func() {
			verdict.Lock()
			defer verdict.Unlock()
			_ = q.SetVerdict(id, nfqueue.NfAccept)
		})
		return 0
	}, report); err != nil {
		_ = q.Close()
		return nil, err
	}
	return q, nil
}

func openLog(ctx context.Context, h *holder, report func(error) int) (*nflog.Nflog, error) {
	nf, err := nflog.Open(&nflog.Config{Group: dnsGroup, Copymode: nflog.CopyPacket, Bufsize: 4096, QThresh: 1})
	if err != nil {
		return nil, err
	}
	if err := nf.RegisterWithErrorFunc(ctx, func(a nflog.Attribute) int {
		if a.Payload != nil {
			h.push(append([]byte(nil), *a.Payload...), nil)
		}
		return 0
	}, report); err != nil {
		_ = nf.Close()
		return nil, err
	}
	return nf, nil
}
