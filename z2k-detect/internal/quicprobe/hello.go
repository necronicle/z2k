package quicprobe

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
)

// ClientHello снимает НАСТОЯЩЕЕ приветствие TLS для указанного имени в том
// виде, в каком его отдал бы QUIC-стек.
//
// Приветствие не конструируется руками по той же причине, что и в TCP-части
// (classify.TLSTrigger): его форма и есть измерительный инструмент. Коробка
// решает по расширениям, порядку и длинам, и самодельный хелло мерил бы не ту
// коробку, что видит браузер. Поэтому берём его у crypto/tls через QUICClient —
// тот же приём, что net.Pipe для TCP, только событийный.
//
// ПОЧЕМУ КРИВАЯ ЗАФИКСИРОВАНА НА X25519. По умолчанию Go 1.24+ предлагает
// постквантовый X25519MLKEM768, и приветствие с ним перестаёт помещаться в одну
// датаграмму — ровно то, что делает Chrome и что само по себе обходит коробку,
// не умеющую пересобирать. Для замера это недопустимо: нарезка должна быть
// НАШИМ решением и отдельным зондом, а не случайным следствием набора кривых.
func ClientHello(sni string, scid []byte) ([]byte, error) {
	if sni == "" {
		return nil, errors.New("quicprobe: пустое имя")
	}
	conn := tls.QUICClient(&tls.QUICConfig{
		TLSConfig: &tls.Config{
			ServerName:       sni,
			MinVersion:       tls.VersionTLS13,
			MaxVersion:       tls.VersionTLS13,
			NextProtos:       []string{"h3"},
			CurvePreferences: []tls.CurveID{tls.X25519},
		},
	})
	defer conn.Close()

	conn.SetTransportParameters(transportParameters(scid))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := conn.Start(ctx); err != nil {
		return nil, fmt.Errorf("quicprobe: старт TLS: %w", err)
	}
	for {
		ev := conn.NextEvent()
		switch ev.Kind {
		case tls.QUICWriteData:
			if ev.Level == tls.QUICEncryptionLevelInitial && len(ev.Data) > 0 {
				// Данные принадлежат crypto/tls до следующего NextEvent.
				return append([]byte(nil), ev.Data...), nil
			}
		case tls.QUICNoEvent:
			return nil, errors.New("quicprobe: crypto/tls не отдал ClientHello")
		}
	}
}

// transportParameters — минимальный, но ЗАКОННЫЙ набор параметров транспорта.
//
// Полениться тут нельзя: сервер их разбирает, и если
// initial_source_connection_id не совпадёт с SCID из нашего заголовка, он
// закроет соединение с ошибкой протокола. Для замера это выглядело бы как
// «блокировка», хотя это была бы наша собственная ошибка.
func transportParameters(scid []byte) []byte {
	var b []byte
	put := func(id uint64, val uint64) {
		b = appendVarint(b, id)
		v := appendVarint(nil, val)
		b = appendVarint(b, uint64(len(v)))
		b = append(b, v...)
	}
	put(0x01, 30000)   // max_idle_timeout, мс
	put(0x03, 1472)    // max_udp_payload_size
	put(0x04, 1048576) // initial_max_data
	put(0x05, 262144)  // initial_max_stream_data_bidi_local
	put(0x06, 262144)  // initial_max_stream_data_bidi_remote
	put(0x07, 262144)  // initial_max_stream_data_uni
	put(0x08, 100)     // initial_max_streams_bidi
	put(0x09, 100)     // initial_max_streams_uni
	// initial_source_connection_id — единственный параметр, который сервер
	// сверяет с заголовком.
	b = appendVarint(b, 0x0f)
	b = appendVarint(b, uint64(len(scid)))
	b = append(b, scid...)
	return b
}

// versionNegotiationProbe собирает датаграмму с ЗАВЕДОМО неизвестной версией.
//
// Это контроль пути, не зависящий от содержимого: внутри нет ни ClientHello,
// ни вообще чего-либо осмысленного, поэтому ответить на него сервер может
// только по одной причине — датаграмма до него дошла. Замер 04.09: Google и
// YouTube отвечают пакетом Version Negotiation за 40–42 мс.
//
// Версия выбрана из зарезервированного под гриз множества 0x?a?a?a?a
// (RFC 9000 §15): такие версии обязаны вызывать согласование, а не разбор.
func versionNegotiationProbe(dcid, scid []byte, size int) []byte {
	b := []byte{0xc0}
	b = binary.BigEndian.AppendUint32(b, 0x1a2a3a4a)
	b = append(b, byte(len(dcid)))
	b = append(b, dcid...)
	b = append(b, byte(len(scid)))
	b = append(b, scid...)
	b = appendVarint(b, 0) // пустой токен
	if len(b) < size {
		b = append(b, make([]byte, size-len(b))...)
	}
	return b
}
