package prober

// Охраняет фикс 2026-08-14: Dial-функция пула обязана чтить запрошенный
// network. Резолвер Go повторяет усечённый (TC=1) UDP-ответ по TCP тем же
// Dial'ом; прибитый "udp" подсовывал этому повтору UDP-сокет, и большие
// ответы превращались в таймаут у всех резолверов разом. Та же ошибка уже
// чинилась в rt-proxy (directResolver) — теперь оба места под тестом.

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestPoolDialHonoursRequestedNetwork(t *testing.T) {
	// TCP-слушатель: если Dial чтит network="tcp", соединение установится
	// и будет *net.TCPConn. Старый код дал бы *net.UDPConn в никуда.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go func() {
		c, aerr := ln.Accept()
		if aerr == nil {
			defer c.Close()
			// Держим соединение, пока тест не закончит проверку.
			buf := make([]byte, 1)
			_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
			_, _ = c.Read(buf)
		}
	}()

	dial := poolDial(ln.Addr().String())
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	conn, err := dial(ctx, "tcp", "ignored:53")
	if err != nil {
		t.Fatalf("dial tcp: %v", err)
	}
	defer conn.Close()
	if _, ok := conn.(*net.TCPConn); !ok {
		t.Fatalf("запросили tcp, получили %T — TCP-повтор усечённого ответа уйдёт в UDP-сокет", conn)
	}

	// И симметрично: udp остаётся udp.
	uconn, err := dial(ctx, "udp", "ignored:53")
	if err != nil {
		t.Fatalf("dial udp: %v", err)
	}
	defer uconn.Close()
	if _, ok := uconn.(*net.UDPConn); !ok {
		t.Fatalf("запросили udp, получили %T", uconn)
	}
}
