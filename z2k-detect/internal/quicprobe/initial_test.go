package quicprobe

import (
	"bytes"
	"encoding/hex"
	"testing"
)

// Тест-векторы RFC 9001 Appendix A. Смысл именно в них: сборка Initial — это
// пять слоёв (кадры, паддинг, AEAD, номер пакета, защита заголовка), и ошибка
// в любом даёт пакет, который сервер молча выбросит. Отличить такую ошибку от
// блокировки В ПОЛЕ НЕЛЬЗЯ — обе выглядят как тишина. Поэтому корректность
// доказывается офлайн, побайтно, до всякой сети.
//
// DCID во всех векторах — 0x8394c8f03e515708.

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("битый вектор: %v", err)
	}
	return b
}

const vecDCID = "8394c8f03e515708"

// RFC 9001 A.1 — вывод ключей из DCID.
func TestRFC9001Keys(t *testing.T) {
	client, server, err := deriveKeys(unhex(t, vecDCID), V1)
	if err != nil {
		t.Fatalf("deriveKeys: %v", err)
	}
	for _, c := range []struct {
		name string
		got  []byte
		want string
	}{
		{"client key", client.key, "1f369613dd76d5467730efcbe3b1a22d"},
		{"client iv", client.iv, "fa044b2f42a3fd3b46fb255c"},
		{"client hp", client.hp, "9f50449e04a0e810283a1e9933adedd2"},
		{"server key", server.key, "cf3a5331653c364c88f0f379b6067e37"},
		{"server iv", server.iv, "0ac1493ca1905853b0bba03e"},
		{"server hp", server.hp, "c206b8d9b9f0f37644430b490eeaa314"},
	} {
		if hex.EncodeToString(c.got) != c.want {
			t.Errorf("%s = %s, ожидалось %s", c.name, hex.EncodeToString(c.got), c.want)
		}
	}
}

// RFC 9001 A.2 — клиентский Initial целиком, побайтно.
func TestRFC9001ClientInitial(t *testing.T) {
	// Вектор даёт кадр CRYPTO вместе с его заголовком (06 00 40f1), а Marshal
	// собирает заголовок сам, поэтому на вход отдаём только данные кадра.
	frame := unhex(t, cryptoFrameVec)
	p := Initial{
		Version:      V1,
		DCID:         unhex(t, vecDCID),
		PacketNumber: 2,
		PNLen:        4,
		Crypto:       []CryptoFrame{{Offset: 0, Data: frame[4:]}},
		DatagramLen:  1200,
	}
	got, err := p.Marshal()
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	want := unhex(t, clientPacketVec)
	if !bytes.Equal(got, want) {
		for i := range want {
			if i >= len(got) || got[i] != want[i] {
				t.Fatalf("расхождение на байте %d: получено %x, ожидалось %x (длина %d против %d)",
					i, got[i:min(i+8, len(got))], want[i:min(i+8, len(want))], len(got), len(want))
			}
		}
		t.Fatalf("длина %d, ожидалось %d", len(got), len(want))
	}
}

// RFC 9001 A.3 — серверный Initial разбирается и расшифровывается ключами,
// выведенными из НАШЕГО DCID. Это и есть оракул: ответ доказан криптографией,
// а не тем, что «на порт что-то прилетело».
func TestRFC9001ServerInitial(t *testing.T) {
	res, err := Parse(unhex(t, serverPacketVec), unhex(t, vecDCID), V1)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if res.Kind != KindInitial {
		t.Fatalf("вид пакета %q, ожидался %q (%s)", res.Kind, KindInitial, res.Note)
	}
	if !res.Answered() {
		t.Fatal("серверный Initial не засчитан за ответ")
	}
	var haveACK, haveCrypto bool
	for _, f := range res.Frames {
		switch f.Type {
		case FrameACK:
			haveACK = true
		case FrameCrypto:
			haveCrypto = true
			if len(f.Data) == 0 {
				t.Error("кадр CRYPTO пуст")
			}
		}
	}
	if !haveACK || !haveCrypto {
		t.Errorf("разобраны кадры %+v, ожидались ACK и CRYPTO", res.Frames)
	}
}

// Чужой пакет не должен засчитываться за ответ. Мотив полевой: 04.09 на
// youtube-именах приходил «Initial», не раскрывающийся нашими ключами.
func TestForeignPacketIsNotAnAnswer(t *testing.T) {
	pkt := unhex(t, serverPacketVec)
	other := unhex(t, "0000000000000000") // чужой DCID — ключи не подойдут
	res, err := Parse(pkt, other, V1)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if res.Answered() {
		t.Fatalf("пакет с чужими ключами засчитан за ответ: %+v", res)
	}
}

// Версия 2 отличается солью, метками и НУМЕРАЦИЕЙ ТИПОВ пакетов. Проверяем,
// что различие видно на проводе: коробка, зашитая на v1, такой Initial не
// разберёт, и это отдельный вопрос к ней.
func TestVersion2DiffersOnTheWire(t *testing.T) {
	mk := func(v Version) []byte {
		p := Initial{Version: v, DCID: unhex(t, vecDCID), PacketNumber: 1, PNLen: 4,
			Crypto: []CryptoFrame{{Data: []byte("hello")}}, DatagramLen: 1200}
		b, err := p.Marshal()
		if err != nil {
			t.Fatalf("Marshal(%#x): %v", uint32(v), err)
		}
		return b
	}
	v1, v2 := mk(V1), mk(V2)
	// Биты типа защитой заголовка не закрыты, поэтому сравнимы напрямую.
	if t1, t2 := (v1[0]&0x30)>>4, (v2[0]&0x30)>>4; t1 == t2 {
		t.Errorf("тип пакета одинаков (%d) для v1 и v2", t1)
	}
	if bytes.Equal(v1[1:5], v2[1:5]) {
		t.Error("поле версии одинаково")
	}
}

// Нарезка ClientHello по нескольким кадрам CRYPTO — наш аналог разреза
// TCP-потока и единственный приём, ломающий РАЗБОР, а не сигнатуру.
// Проверяем, что кадры с произвольными смещениями и в обратном порядке
// собираются и разбираются обратно без потерь.
func TestSplitCryptoRoundTrip(t *testing.T) {
	dcid := unhex(t, vecDCID)
	hello := bytes.Repeat([]byte("ABCD"), 40)
	p := Initial{
		Version: V1, DCID: dcid, PacketNumber: 0, PNLen: 4, DatagramLen: 1200,
		Crypto: []CryptoFrame{
			{Offset: 100, Data: hello[100:]},
			{Offset: 0, Data: hello[:100]},
		},
	}
	pkt, err := p.Marshal()
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if len(pkt) != 1200 {
		t.Fatalf("датаграмма %d байт, ожидалось 1200", len(pkt))
	}
	// Parse умеет только серверное направление, поэтому свой же пакет
	// раскрываем нижним слоем напрямую.
	client, _, err := deriveKeys(dcid, V1)
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, len(pkt))
	copy(buf, pkt)
	pnOffset := 1 + 4 + 1 + len(dcid) + 1 + 0 + 1 + 2
	if err := applyHeaderProtection(buf, client.hp, pnOffset, 4, true); err != nil {
		t.Fatal(err)
	}
	length, n := readVarint(buf[pnOffset-2:])
	if n == 0 {
		t.Fatal("не прочиталась длина")
	}
	plain, err := open(client, buf[pnOffset+4:pnOffset+int(length)], buf[:pnOffset+4], 0)
	if err != nil {
		t.Fatalf("не расшифровался собственный пакет: %v", err)
	}
	var got []byte
	for _, f := range parseFrames(plain) {
		if f.Type != FrameCrypto {
			continue
		}
		if need := int(f.Offset) + len(f.Data); len(got) < need {
			got = append(got, make([]byte, need-len(got))...)
		}
		copy(got[f.Offset:], f.Data)
	}
	if !bytes.Equal(got, hello) {
		t.Errorf("после сборки кадров получено %d байт, ожидалось %d", len(got), len(hello))
	}
}

const cryptoFrameVec = "060040f1010000ed0303ebf8fa56f129" +
	"39b9584a3896472ec40bb863cfd3e868" +
	"04fe3a47f06a2b69484c000004130113" +
	"02010000c000000010000e00000b6578" +
	"616d706c652e636f6dff01000100000a" +
	"00080006001d00170018001000070005" +
	"04616c706e0005000501000000000033" +
	"00260024001d00209370b2c9caa47fba" +
	"baf4559fedba753de171fa71f50f1ce1" +
	"5d43e994ec74d748002b000302030400" +
	"0d0010000e0403050306030203080408" +
	"050806002d00020101001c0002400100" +
	"3900320408ffffffffffffffff050480" +
	"00ffff07048000ffff08011001048000" +
	"75300901100f088394c8f03e51570806" +
	"048000ffff"

const clientPacketVec = "c000000001088394c8f03e5157080000" +
	"449e7b9aec34d1b1c98dd7689fb8ec11" +
	"d242b123dc9bd8bab936b47d92ec356c" +
	"0bab7df5976d27cd449f63300099f399" +
	"1c260ec4c60d17b31f8429157bb35a12" +
	"82a643a8d2262cad67500cadb8e7378c" +
	"8eb7539ec4d4905fed1bee1fc8aafba1" +
	"7c750e2c7ace01e6005f80fcb7df6212" +
	"30c83711b39343fa028cea7f7fb5ff89" +
	"eac2308249a02252155e2347b63d58c5" +
	"457afd84d05dfffdb20392844ae81215" +
	"4682e9cf012f9021a6f0be17ddd0c208" +
	"4dce25ff9b06cde535d0f920a2db1bf3" +
	"62c23e596d11a4f5a6cf3948838a3aec" +
	"4e15daf8500a6ef69ec4e3feb6b1d98e" +
	"610ac8b7ec3faf6ad760b7bad1db4ba3" +
	"485e8a94dc250ae3fdb41ed15fb6a8e5" +
	"eba0fc3dd60bc8e30c5c4287e53805db" +
	"059ae0648db2f64264ed5e39be2e20d8" +
	"2df566da8dd5998ccabdae053060ae6c" +
	"7b4378e846d29f37ed7b4ea9ec5d82e7" +
	"961b7f25a9323851f681d582363aa5f8" +
	"9937f5a67258bf63ad6f1a0b1d96dbd4" +
	"faddfcefc5266ba6611722395c906556" +
	"be52afe3f565636ad1b17d508b73d874" +
	"3eeb524be22b3dcbc2c7468d54119c74" +
	"68449a13d8e3b95811a198f3491de3e7" +
	"fe942b330407abf82a4ed7c1b311663a" +
	"c69890f4157015853d91e923037c227a" +
	"33cdd5ec281ca3f79c44546b9d90ca00" +
	"f064c99e3dd97911d39fe9c5d0b23a22" +
	"9a234cb36186c4819e8b9c5927726632" +
	"291d6a418211cc2962e20fe47feb3edf" +
	"330f2c603a9d48c0fcb5699dbfe58964" +
	"25c5bac4aee82e57a85aaf4e2513e4f0" +
	"5796b07ba2ee47d80506f8d2c25e50fd" +
	"14de71e6c418559302f939b0e1abd576" +
	"f279c4b2e0feb85c1f28ff18f58891ff" +
	"ef132eef2fa09346aee33c28eb130ff2" +
	"8f5b766953334113211996d20011a198" +
	"e3fc433f9f2541010ae17c1bf202580f" +
	"6047472fb36857fe843b19f5984009dd" +
	"c324044e847a4f4a0ab34f719595de37" +
	"252d6235365e9b84392b061085349d73" +
	"203a4a13e96f5432ec0fd4a1ee65accd" +
	"d5e3904df54c1da510b0ff20dcc0c77f" +
	"cb2c0e0eb605cb0504db87632cf3d8b4" +
	"dae6e705769d1de354270123cb11450e" +
	"fc60ac47683d7b8d0f811365565fd98c" +
	"4c8eb936bcab8d069fc33bd801b03ade" +
	"a2e1fbc5aa463d08ca19896d2bf59a07" +
	"1b851e6c239052172f296bfb5e724047" +
	"90a2181014f3b94a4e97d117b4381303" +
	"68cc39dbb2d198065ae3986547926cd2" +
	"162f40a29f0c3c8745c0f50fba3852e5" +
	"66d44575c29d39a03f0cda721984b6f4" +
	"40591f355e12d439ff150aab7613499d" +
	"bd49adabc8676eef023b15b65bfc5ca0" +
	"6948109f23f350db82123535eb8a7433" +
	"bdabcb909271a6ecbcb58b936a88cd4e" +
	"8f2e6ff5800175f113253d8fa9ca8885" +
	"c2f552e657dc603f252e1a8e308f76f0" +
	"be79e2fb8f5d5fbbe2e30ecadd220723" +
	"c8c0aea8078cdfcb3868263ff8f09400" +
	"54da48781893a7e49ad5aff4af300cd8" +
	"04a6b6279ab3ff3afb64491c85194aab" +
	"760d58a606654f9f4400e8b38591356f" +
	"bf6425aca26dc85244259ff2b19c41b9" +
	"f96f3ca9ec1dde434da7d2d392b905dd" +
	"f3d1f9af93d1af5950bd493f5aa731b4" +
	"056df31bd267b6b90a079831aaf579be" +
	"0a39013137aac6d404f518cfd4684064" +
	"7e78bfe706ca4cf5e9c5453e9f7cfd2b" +
	"8b4c8d169a44e55c88d4a9a7f9474241" +
	"e221af44860018ab0856972e194cd934"

const serverPacketVec = "cf000000010008f067a5502a4262b500" +
	"4075c0d95a482cd0991cd25b0aac406a" +
	"5816b6394100f37a1c69797554780bb3" +
	"8cc5a99f5ede4cf73c3ec2493a1839b3" +
	"dbcba3f6ea46c5b7684df3548e7ddeb9" +
	"c3bf9c73cc3f3bded74b562bfb19fb84" +
	"022f8ef4cdd93795d77d06edbb7aaf2f" +
	"58891850abbdca3d20398c276456cbc4" +
	"2158407dd074ee"
