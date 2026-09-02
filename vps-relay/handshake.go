package main

import (
	"crypto/rand"
	"crypto/subtle"
	"fmt"
	"log"
	"time"

	"github.com/gorilla/websocket"
)

// handshake определяет протокол по первому кадру и авторизует (спека §2.4).
// v1: 0x06 (88 байт) или 0x00 (общий секрет, отвергается молча).
// v2: HELLO → HELLO_ACK(nonce) → AUTHID v2 (104 байта, подпись над id||ts||nonce).
func (s *session) handshake() bool {
	s.ws.SetReadLimit(2 * 1024 * 1024)
	_ = s.ws.SetReadDeadline(time.Now().Add(*authReadTimeout))
	s.ws.SetPongHandler(func(string) error {
		_ = s.ws.SetReadDeadline(time.Now().Add(*authReadTimeout))
		return nil
	})
	s.ws.SetPingHandler(func(data string) error {
		_ = s.ws.SetReadDeadline(time.Now().Add(*authReadTimeout))
		return s.ws.WriteControl(websocket.PongMessage, []byte(data), time.Now().Add(5*time.Second))
	})

	sid, mt, p, ok := s.readAuthFrame("auth_read_err")
	if !ok {
		return false
	}
	if sid != 0 {
		log.Printf("[%s] first message not auth (sid=%d type=0x%02x)", s.id, sid, mt)
		s.killWith("first_not_auth")
		return false
	}
	switch mt {
	case muxHELLO:
		return s.handshakeV2(p)
	case muxAUTHID, muxAUTH:
		return s.handshakeV1(mt, p)
	default:
		log.Printf("[%s] first message not auth (type=0x%02x)", s.id, mt)
		s.killWith("first_not_auth")
		return false
	}
}

func (s *session) readAuthFrame(errPrefix string) (uint16, byte, []byte, bool) {
	_, msg, err := s.ws.ReadMessage()
	if err != nil {
		if *verbose {
			log.Printf("[%s] %s: %v", s.id, errPrefix, err)
		}
		s.killWith(classifyReadErr(err, errPrefix))
		return 0, 0, nil, false
	}
	sid, mt, p, err := decodeFrame(msg)
	if err != nil {
		s.killWith("first_not_auth")
		return 0, 0, nil, false
	}
	return sid, mt, p, true
}

func (s *session) handshakeV1(mt byte, p []byte) bool {
	s.pr = protoV1
	var relayID, scheme, why string
	authedOK := false
	if mt == muxAUTHID {
		relayID, authedOK, why = verifyPerInstallAuth(p)
		scheme = "per-install"
	} else if !*requirePerInstall {
		authedOK = subtle.ConstantTimeCompare(p, computeAuthHMAC(*secret)) == 1
		if !authedOK && *secretPrev != "" {
			authedOK = subtle.ConstantTimeCompare(p, computeAuthHMAC(*secretPrev)) == 1
		}
		scheme = "shared-secret"
		if !authedOK {
			why = "общий секрет не совпал"
		}
	}
	legacyScheme := false
	if why == "" && !authedOK {
		// Кадр 0x00 при включённом требовании персональной схемы: клиент до
		// r-76.2. Не логируется по решению 18.08.2026 — треть журнала.
		why = "старая схема (общий секрет) при включённом требовании персональной"
		legacyScheme = true
	}
	if !authedOK {
		if !legacyScheme {
			log.Printf("[%s] auth rejected (type=0x%02x scheme=%s id=%s): %s", s.id, mt, scheme, relayID, why)
			emitEvent(Event{Ev: "auth_reject", SID: s.id, IP: s.clientIP, Install: relayID, Reason: why})
			metrics.inc("relay_auth_reject_total", fmt.Sprintf("reason=%q", authRejectClass(why)))
		}
		s.killWith("auth_rejected")
		return false
	}
	s.relayID = relayID
	return true
}

func (s *session) handshakeV2(p []byte) bool {
	s.pr = protoV2
	h, err := decodeHello(p)
	if err != nil || h.Ver != protoVersion2 {
		s.goodbye(rProtocol, "HELLO не разобран")
		s.killWith("protocol")
		return false
	}
	s.build = h.Build
	if _, err := rand.Read(s.nonce[:]); err != nil {
		s.killWith("internal")
		return false
	}
	ack := helloAck{Ver: protoVersion2, ServerUnix: time.Now().Unix(), Nonce: s.nonce,
		MinBuild: *minBuild, DefaultWindow: uint32(*defaultWindow)}
	s.writer.control(encodeFrame(0, muxHELLO_ACK, encodeHelloAck(ack)))

	sid, mt, p, ok := s.readAuthFrame("auth_read_err")
	if !ok {
		return false
	}
	if sid != 0 || mt != muxAUTHID {
		s.goodbye(rProtocol, "после HELLO ожидался AUTHID")
		s.killWith("first_not_auth")
		return false
	}
	a, err := decodeAuthV2(p)
	if err != nil {
		s.goodbye(rProtocol, err.Error())
		s.killWith("auth_rejected")
		return false
	}
	id, ok, why, code := verifyPerInstallAuthV2(a, s.nonce)
	if !ok {
		log.Printf("[%s] auth rejected (v2 id=%s): %s", s.id, id, why)
		emitEvent(Event{Ev: "auth_reject", SID: s.id, IP: s.clientIP, Install: id, Reason: why})
		metrics.inc("relay_auth_reject_total", fmt.Sprintf("reason=%q", authRejectClass(why)))
		if code == rClockSkew {
			skew := int32(a.TS - time.Now().Unix())
			s.writer.control(s.pr.info(infoClockSkew, uint32(skew), ""))
		}
		s.goodbye(code, why)
		s.killWith("auth_rejected")
		return false
	}
	s.relayID = id
	return true
}
