package quicprobe

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// Kind — что за пакет нам прилетел.
type Kind string

const (
	// KindInitial — серверный Initial, РАСШИФРОВАННЫЙ ключами из нашего DCID.
	// Только это доказывает, что нам ответил тот, кому мы писали.
	KindInitial Kind = "initial"
	// KindRetry — сервер требует повторить с токеном. Тоже доказательство
	// жизни: Retry шлёт сервер, а не коробка.
	KindRetry Kind = "retry"
	// KindVersionNegotiation — версия не поддержана. Ценно тем, что ответ
	// НЕ ЗАВИСИТ ОТ СОДЕРЖИМОГО: он доказывает, что адрес и путь живы, даже
	// когда всё остальное режут.
	KindVersionNegotiation Kind = "version_negotiation"
	// KindForeign — похоже на QUIC, но нашими ключами не раскрывается. Замер
	// 04.09: именно так выглядел «Initial» с нулевым DCID на youtube-именах.
	// За ответ сервера такое считать нельзя.
	KindForeign Kind = "foreign"
)

// FrameType — тип кадра внутри расшифрованной нагрузки. Перечислены только те,
// что вообще разрешены в Initial (RFC 9000 §17.2.2).
type FrameType string

const (
	FramePadding         FrameType = "padding"
	FramePing            FrameType = "ping"
	FrameACK             FrameType = "ack"
	FrameCrypto          FrameType = "crypto"
	FrameConnectionClose FrameType = "connection_close"
)

// Frame — разобранный кадр. Data заполняется только у CRYPTO.
type Frame struct {
	Type   FrameType
	Offset uint64
	Data   []byte
	// ErrorCode и Reason — для CONNECTION_CLOSE. Это отдельный ценный исход:
	// сервер, который не обслуживает наше имя, отвечает закрытием с TLS-алертом,
	// и это НЕ блокировка. Без такого разбора «сервер не знает имени» и «коробка
	// убила» слились бы в одну тишину.
	ErrorCode uint64
	Reason    string
}

// Response — разобранный ответ.
type Response struct {
	Kind     Kind
	Version  Version
	DCID     []byte
	SCID     []byte
	Frames   []Frame
	Versions []Version
	Note     string
}

// Answered — считать ли пакет доказательством, что до сервера дошло.
//
// Правило намеренно жёсткое. Инъекции коробок в UDP не наблюдались, но
// наблюдался пакет, похожий на ответ и не раскрывающийся нашими ключами
// (замер 04.09, cloudflare-quic.com на youtube-именах, 2/2 повтора, задержка
// как у живого ответа). Что это было — инъекция или неизвестное поведение
// сервера — не установлено, и именно поэтому за успех оно не считается.
func (r Response) Answered() bool {
	return r.Kind == KindInitial || r.Kind == KindRetry || r.Kind == KindVersionNegotiation
}

// Parse разбирает датаграмму, пришедшую в ответ на наш Initial с dcid.
func Parse(pkt, dcid []byte, v Version) (Response, error) {
	if len(pkt) < 7 {
		return Response{}, errors.New("quicprobe: датаграмма короче заголовка")
	}
	if pkt[0]&0x80 == 0 {
		// Короткий заголовок: до него в нашем разговоре дело не доходит,
		// ключей уровня приложения у нас нет.
		return Response{Kind: KindForeign, Note: "короткий заголовок"}, nil
	}
	ver := Version(binary.BigEndian.Uint32(pkt[1:5]))

	off := 5
	dcidLen := int(pkt[off])
	off++
	if off+dcidLen > len(pkt) {
		return Response{}, errors.New("quicprobe: обрезан DCID")
	}
	rDCID := pkt[off : off+dcidLen]
	off += dcidLen
	if off >= len(pkt) {
		return Response{}, errors.New("quicprobe: обрезан SCID")
	}
	scidLen := int(pkt[off])
	off++
	if off+scidLen > len(pkt) {
		return Response{}, errors.New("quicprobe: обрезан SCID")
	}
	rSCID := pkt[off : off+scidLen]
	off += scidLen

	res := Response{Version: ver, DCID: rDCID, SCID: rSCID}

	// Version Negotiation опознаётся по нулевой версии, а не по типу пакета.
	if ver == 0 {
		res.Kind = KindVersionNegotiation
		for i := off; i+4 <= len(pkt); i += 4 {
			res.Versions = append(res.Versions, Version(binary.BigEndian.Uint32(pkt[i:i+4])))
		}
		return res, nil
	}

	typ := (pkt[0] & 0x30) >> 4 // биты типа защитой заголовка НЕ закрыты
	if typ == retryType(v) && ver == v {
		res.Kind = KindRetry
		return res, nil
	}
	if typ != initialType(v) || ver != v {
		res.Kind = KindForeign
		res.Note = fmt.Sprintf("тип %d версия %#08x", typ, uint32(ver))
		return res, nil
	}

	// Токен и длина.
	tokLen, n := readVarint(pkt[off:])
	if n == 0 || off+n+int(tokLen) > len(pkt) {
		return Response{}, errors.New("quicprobe: обрезан токен")
	}
	off += n + int(tokLen)
	length, n := readVarint(pkt[off:])
	if n == 0 {
		return Response{}, errors.New("quicprobe: обрезано поле длины")
	}
	off += n
	pnOffset := off
	if pnOffset+int(length) > len(pkt) {
		return Response{}, errors.New("quicprobe: длина больше датаграммы")
	}

	_, server, err := deriveKeys(dcid, v)
	if err != nil {
		return Response{}, err
	}

	// Снятие защиты заголовка портит буфер, поэтому работаем на копии: тот же
	// массив может понадобиться вызывающему для дампа.
	buf := make([]byte, len(pkt))
	copy(buf, pkt)
	if err := applyHeaderProtection(buf, server.hp, pnOffset, 4, true); err != nil {
		return Response{Kind: KindForeign, Note: "не хватает байт на выборку"}, nil
	}
	pnLen := int(buf[0]&0x03) + 1
	// Маску мы наложили на четыре байта, а номер короче — лишние байты надо
	// вернуть на место, иначе испортим шифротекст.
	if pnLen < 4 {
		copy(buf[pnOffset+pnLen:pnOffset+4], pkt[pnOffset+pnLen:pnOffset+4])
	}
	var pn uint32
	for i := 0; i < pnLen; i++ {
		pn = pn<<8 | uint32(buf[pnOffset+i])
	}

	aad := buf[:pnOffset+pnLen]
	ct := buf[pnOffset+pnLen : pnOffset+int(length)]
	plain, err := open(server, ct, aad, pn)
	if err != nil {
		res.Kind = KindForeign
		res.Note = "не раскрывается нашими ключами"
		return res, nil
	}
	res.Kind = KindInitial
	res.Frames = parseFrames(plain)
	return res, nil
}

// parseFrames разбирает нагрузку Initial. Неизвестные кадры обрывают разбор:
// в Initial их быть не может, а гадать о длине неизвестного кадра нельзя.
func parseFrames(b []byte) []Frame {
	var out []Frame
	i := 0
	for i < len(b) {
		switch b[i] {
		case 0x00: // PADDING — схлопываем в один кадр
			j := i
			for j < len(b) && b[j] == 0x00 {
				j++
			}
			out = append(out, Frame{Type: FramePadding, Offset: uint64(j - i)})
			i = j
		case 0x01:
			out = append(out, Frame{Type: FramePing})
			i++
		case 0x02, 0x03:
			f, n := parseACK(b[i:])
			if n == 0 {
				return out
			}
			out = append(out, f)
			i += n
		case 0x06:
			off, n1 := readVarint(b[i+1:])
			if n1 == 0 {
				return out
			}
			ln, n2 := readVarint(b[i+1+n1:])
			if n2 == 0 {
				return out
			}
			start := i + 1 + n1 + n2
			if start+int(ln) > len(b) {
				return out
			}
			out = append(out, Frame{Type: FrameCrypto, Offset: off, Data: b[start : start+int(ln)]})
			i = start + int(ln)
		case 0x1c, 0x1d:
			f, n := parseConnectionClose(b[i:])
			if n == 0 {
				return out
			}
			out = append(out, f)
			i += n
		default:
			return out
		}
	}
	return out
}

func parseACK(b []byte) (Frame, int) {
	i := 1
	for k := 0; k < 4; k++ { // largest, delay, range count, first range
		_, n := readVarint(b[i:])
		if n == 0 {
			return Frame{}, 0
		}
		i += n
	}
	return Frame{Type: FrameACK}, i
}

func parseConnectionClose(b []byte) (Frame, int) {
	i := 1
	code, n := readVarint(b[i:])
	if n == 0 {
		return Frame{}, 0
	}
	i += n
	if b[0] == 0x1c { // тип кадра, вызвавшего ошибку, есть только у 0x1c
		_, n = readVarint(b[i:])
		if n == 0 {
			return Frame{}, 0
		}
		i += n
	}
	rl, n := readVarint(b[i:])
	if n == 0 || i+n+int(rl) > len(b) {
		return Frame{}, 0
	}
	i += n
	reason := string(b[i : i+int(rl)])
	return Frame{Type: FrameConnectionClose, ErrorCode: code, Reason: reason}, i + int(rl)
}
