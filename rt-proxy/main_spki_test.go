package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"testing"
	"time"
)

// В probeProxy по внутреннему рукопожатию принимается решение «узел живой», и
// клиент там — мы сами, а не браузер. Обоснование «MITM невозможен, потому что
// внутри сквозной TLS» для этой точки ложно: подставной узел завершает TLS
// своим ключом, отдаёт правдоподобный мусор и остаётся в кольце.
func mkCert(t *testing.T) []byte {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("ключ: %v", err)
	}
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "probe"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	if err != nil {
		t.Fatalf("сертификат: %v", err)
	}
	return der
}

func TestVerifyHealthSPKIAcceptsMatching(t *testing.T) {
	der := mkCert(t)
	leaf, _ := x509.ParseCertificate(der)
	old := *healthSPKIPin
	*healthSPKIPin = spkiFingerprint(leaf)
	t.Cleanup(func() { *healthSPKIPin = old })

	if err := verifyHealthSPKI([][]byte{der}); err != nil {
		t.Fatalf("совпадающий ключ должен приниматься: %v", err)
	}
}

func TestVerifyHealthSPKIRejectsOtherKey(t *testing.T) {
	mine := mkCert(t)
	leaf, _ := x509.ParseCertificate(mine)
	old := *healthSPKIPin
	*healthSPKIPin = spkiFingerprint(leaf)
	t.Cleanup(func() { *healthSPKIPin = old })

	// Подставной узел: валидный TLS, но ЧУЖОЙ ключ.
	if err := verifyHealthSPKI([][]byte{mkCert(t)}); err == nil {
		t.Fatal("чужой ключ обязан отвергаться — это и есть health-poisoning")
	}
}

// Пустой пин сохраняет прежнее поведение. Это осознанный дефолт: цель нам не
// принадлежит, и TOFU при легальной смене ключа уронил бы проверку у всех узлов
// разом, опустошив пул.
func TestVerifyHealthSPKIEmptyPinAccepts(t *testing.T) {
	old := *healthSPKIPin
	*healthSPKIPin = ""
	t.Cleanup(func() { *healthSPKIPin = old })

	if err := verifyHealthSPKI([][]byte{mkCert(t)}); err != nil {
		t.Fatalf("без пина проверки быть не должно: %v", err)
	}
}

func TestVerifyHealthSPKIRejectsEmptyChain(t *testing.T) {
	if err := verifyHealthSPKI(nil); err == nil {
		t.Fatal("отсутствие сертификата обязано отвергаться")
	}
}
