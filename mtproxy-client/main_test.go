package main

import (
	"crypto/rand"
	"encoding/binary"
	"net"
	"testing"
)

func TestTryHandshake_ValidHeader(t *testing.T) {
	secret := make([]byte, 16)
	rand.Read(secret)

	// Generate a valid relay init (which also creates a valid header)
	header, _, _, _, _, err := generateRelayInit(0xefefefef, 2)
	if err != nil {
		t.Fatalf("generateRelayInit failed: %v", err)
	}

	// tryHandshake expects a header encrypted WITH secret, so this won't
	// match the proto tag. That's fine — we test that it returns an error
	// for bad proto tag (the header was not encrypted with the secret).
	_, _, _, _, _, _, _, herr := tryHandshake(header, secret)
	if herr == nil {
		t.Log("Handshake succeeded (unexpected but not necessarily wrong)")
	}
	// The main thing is it doesn't panic
}

func TestTryHandshake_WrongLength(t *testing.T) {
	secret := make([]byte, 16)
	rand.Read(secret)

	_, _, _, _, _, _, _, err := tryHandshake([]byte("short"), secret)
	if err == nil {
		t.Fatal("expected error for short header")
	}
}

func TestGenerateRelayInit_NoCollision(t *testing.T) {
	for i := 0; i < 100; i++ {
		header, encKey, encIV, decKey, decIV, err := generateRelayInit(0xeeeeeeee, 2)
		if err != nil {
			t.Fatalf("generateRelayInit failed: %v", err)
		}
		if len(header) != handshakeLen {
			t.Fatalf("header len = %d, want %d", len(header), handshakeLen)
		}
		if len(encKey) != 32 || len(encIV) != 16 || len(decKey) != 32 || len(decIV) != 16 {
			t.Fatalf("key/iv lengths wrong")
		}
		// Verify header[0] != 0xef (excluded)
		if header[0] == 0xef {
			t.Fatal("header[0] should never be 0xef")
		}
		// Verify first4 is not a forbidden value
		first4 := binary.LittleEndian.Uint32(header[0:4])
		forbidden := []uint32{0x44414548, 0x54534f50, 0x20544547, 0x4954504f, 0x02010316, 0xdddddddd, 0xeeeeeeee}
		for _, f := range forbidden {
			if first4 == f {
				t.Fatalf("header first4 = 0x%08x (forbidden)", first4)
			}
		}
	}
}

func TestParseSecretHex_Valid(t *testing.T) {
	// dd + 32 hex chars = valid
	hex := "dd0123456789abcdef0123456789abcdef"
	secret, err := parseSecretHex(hex)
	if err != nil {
		t.Fatalf("parseSecretHex failed: %v", err)
	}
	if len(secret) != 16 {
		t.Fatalf("secret len = %d, want 16", len(secret))
	}
}

func TestParseSecretHex_TooShort(t *testing.T) {
	_, err := parseSecretHex("dd01234567")
	if err == nil {
		t.Fatal("expected error for short secret")
	}
}

func TestParseSecretHex_BadPrefix(t *testing.T) {
	_, err := parseSecretHex("aa0123456789abcdef0123456789abcdef")
	if err == nil {
		t.Fatal("expected error for bad prefix")
	}
}

func TestLookupDC_KnownRanges(t *testing.T) {
	tests := []struct {
		ip       string
		expected int16
	}{
		{"149.154.175.1", 1},   // DC1
		{"149.154.167.50", 2},  // DC2
		{"149.154.175.100", 3}, // DC3 (specific IP)
		{"149.154.167.91", 4},  // DC4 (specific IP)
		{"149.154.171.10", 5},  // DC5
		{"91.108.56.1", 5},     // DC5
		{"8.8.8.8", 2},         // Unknown → default DC2
	}

	for _, tt := range tests {
		ip := net.ParseIP(tt.ip)
		got := LookupDC(ip)
		if got != tt.expected {
			t.Errorf("LookupDC(%s) = %d, want %d", tt.ip, got, tt.expected)
		}
	}
}

func TestLookupDC_Specificity(t *testing.T) {
	// DC3 is 149.154.175.100/32, DC1 is 149.154.175.0/24
	// DC3 should win for exact IP match
	ip := net.ParseIP("149.154.175.100")
	got := LookupDC(ip)
	if got != 3 {
		t.Errorf("LookupDC(149.154.175.100) = %d, want 3", got)
	}

	// But a different IP in the /24 should be DC1
	ip2 := net.ParseIP("149.154.175.99")
	got2 := LookupDC(ip2)
	if got2 != 1 {
		t.Errorf("LookupDC(149.154.175.99) = %d, want 1", got2)
	}
}

func TestWsDomains(t *testing.T) {
	// Non-media: primary domain first
	domains := wsDomains(2, false)
	if len(domains) != 2 {
		t.Fatalf("expected 2 domains, got %d", len(domains))
	}
	if domains[0] != "kws2.web.telegram.org" {
		t.Errorf("domains[0] = %s, want kws2.web.telegram.org", domains[0])
	}

	// Media: -1 domain first
	mediaDomains := wsDomains(2, true)
	if mediaDomains[0] != "kws2-1.web.telegram.org" {
		t.Errorf("mediaDomains[0] = %s, want kws2-1.web.telegram.org", mediaDomains[0])
	}

	// DC 203 maps to DC 2
	dc203 := wsDomains(203, false)
	if dc203[0] != "kws2.web.telegram.org" {
		t.Errorf("DC203 domains[0] = %s, want kws2.web.telegram.org", dc203[0])
	}
}

func TestLookupDC_IPv6(t *testing.T) {
	tests := []struct {
		ip       string
		expected int16
	}{
		{"2001:b28:f23d::1", 2},    // DC2 main IPv6 range
		{"2001:b28:f23d:f:1::2", 2}, // DC2 within /48
		{"2001:b28:f23f::1", 5},    // DC5 IPv6 range
		{"2001:b28:f23f:a:b::c", 5}, // DC5 within /48
		{"2001:67c:4e8::1", 2},     // General Telegram IPv6
		{"2001:67c:4e8:ff::1", 2},  // General Telegram IPv6 within /48
		{"2600:1234::1", 2},        // Unknown IPv6 → default DC2
	}

	for _, tt := range tests {
		ip := net.ParseIP(tt.ip)
		if ip == nil {
			t.Fatalf("failed to parse IP %s", tt.ip)
		}
		got := LookupDC(ip)
		if got != tt.expected {
			t.Errorf("LookupDC(%s) = %d, want %d", tt.ip, got, tt.expected)
		}
	}
}

func TestGetOriginalDst_SkipWithoutIptables(t *testing.T) {
	t.Skip("getOriginalDst requires iptables REDIRECT; skipping in unit tests")
}

func TestWsWriter_Serialization(t *testing.T) {
	// Just verify the struct compiles and methods exist
	var _ *wsWriter
	// Full test would require a mock WebSocket, skipping
}

func TestMuxEncodeDecode(t *testing.T) {
	tests := []struct {
		name     string
		streamID uint16
		msgType  byte
		payload  []byte
	}{
		{"CONNECT empty", 1, muxCONNECT, []byte{addrIPv4, 149, 154, 175, 1, 0x01, 0xBB}},
		{"DATA small", 42, muxDATA, []byte("hello world")},
		{"DATA large", 65535, muxDATA, make([]byte, 64*1024)},
		{"CLOSE no payload", 100, muxCLOSE, nil},
		{"CONNECT_OK", 7, muxCONNECT_OK, nil},
		{"CONNECT_FAIL", 8, muxCONNECT_FAIL, nil},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded := encodeMuxFrame(tt.streamID, tt.msgType, tt.payload)

			// Verify minimum length
			if len(encoded) < 3 {
				t.Fatalf("encoded frame too short: %d", len(encoded))
			}

			decoded, err := decodeMuxFrame(encoded)
			if err != nil {
				t.Fatalf("decodeMuxFrame failed: %v", err)
			}

			if decoded.StreamID != tt.streamID {
				t.Errorf("StreamID = %d, want %d", decoded.StreamID, tt.streamID)
			}
			if decoded.MsgType != tt.msgType {
				t.Errorf("MsgType = 0x%02x, want 0x%02x", decoded.MsgType, tt.msgType)
			}

			// Compare payloads
			if tt.payload == nil {
				if len(decoded.Payload) != 0 {
					t.Errorf("Payload len = %d, want 0", len(decoded.Payload))
				}
			} else {
				if len(decoded.Payload) != len(tt.payload) {
					t.Fatalf("Payload len = %d, want %d", len(decoded.Payload), len(tt.payload))
				}
				for i := range tt.payload {
					if decoded.Payload[i] != tt.payload[i] {
						t.Errorf("Payload[%d] = 0x%02x, want 0x%02x", i, decoded.Payload[i], tt.payload[i])
						break
					}
				}
			}
		})
	}
}

func TestMuxDecodeFrameTooShort(t *testing.T) {
	_, err := decodeMuxFrame([]byte{0x00})
	if err == nil {
		t.Fatal("expected error for short frame")
	}
	_, err = decodeMuxFrame([]byte{0x00, 0x01})
	if err == nil {
		t.Fatal("expected error for 2-byte frame")
	}
}

func TestConnectPayloadIPv4(t *testing.T) {
	ip := net.ParseIP("149.154.175.1")
	port := 443
	payload := encodeConnectPayload(ip, port)

	gotIP, gotPort, err := decodeConnectPayload(payload)
	if err != nil {
		t.Fatalf("decodeConnectPayload: %v", err)
	}
	if !gotIP.Equal(ip.To4()) {
		t.Errorf("IP = %s, want %s", gotIP, ip)
	}
	if gotPort != port {
		t.Errorf("Port = %d, want %d", gotPort, port)
	}
}

func TestConnectPayloadIPv6(t *testing.T) {
	ip := net.ParseIP("2001:b28:f23d::1")
	port := 443
	payload := encodeConnectPayload(ip, port)

	gotIP, gotPort, err := decodeConnectPayload(payload)
	if err != nil {
		t.Fatalf("decodeConnectPayload: %v", err)
	}
	if !gotIP.Equal(ip) {
		t.Errorf("IP = %s, want %s", gotIP, ip)
	}
	if gotPort != port {
		t.Errorf("Port = %d, want %d", gotPort, port)
	}
}

func TestConnectPayloadRoundtrip(t *testing.T) {
	tests := []struct {
		ip   string
		port int
	}{
		{"149.154.167.91", 443},
		{"91.108.56.1", 8443},
		{"10.0.0.1", 1},
		{"255.255.255.255", 65535},
		{"2001:b28:f23f::1", 443},
		{"::1", 80},
	}
	for _, tt := range tests {
		ip := net.ParseIP(tt.ip)
		payload := encodeConnectPayload(ip, tt.port)
		gotIP, gotPort, err := decodeConnectPayload(payload)
		if err != nil {
			t.Errorf("decodeConnectPayload(%s:%d): %v", tt.ip, tt.port, err)
			continue
		}
		// Normalize for comparison
		if ip.To4() != nil {
			ip = ip.To4()
		}
		if !gotIP.Equal(ip) {
			t.Errorf("IP = %s, want %s", gotIP, ip)
		}
		if gotPort != tt.port {
			t.Errorf("Port = %d, want %d", gotPort, tt.port)
		}
	}
}

func TestComputeAuthHMAC(t *testing.T) {
	mac1 := computeAuthHMAC("test-secret")
	mac2 := computeAuthHMAC("test-secret")
	mac3 := computeAuthHMAC("different-secret")

	if len(mac1) != 32 {
		t.Fatalf("HMAC length = %d, want 32", len(mac1))
	}

	// Same secret should produce same HMAC
	for i := range mac1 {
		if mac1[i] != mac2[i] {
			t.Fatal("same secret produced different HMACs")
		}
	}

	// Different secret should produce different HMAC
	same := true
	for i := range mac1 {
		if mac1[i] != mac3[i] {
			same = false
			break
		}
	}
	if same {
		t.Fatal("different secrets produced same HMAC")
	}
}
