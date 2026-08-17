package prober

import "testing"

// Первый вопрос поддержки по любому домену — «обход тут вообще поможет?».
// Ответ на него даёт classifyPath: путь до сервера живой и режут по имени
// (десинк применим) или режут сам адрес (пакетными техниками не обходится
// в принципе — так прямо и написано в мануале движка).
//
// Приём взят оттуда же: стучимся к ТОМУ ЖЕ адресу с заведомо не
// заблокированным именем. Ответил — значит дело в имени.
func TestClassifyPath(t *testing.T) {
	yes := true
	cases := []struct {
		name        string
		r           Result
		neutralOK   bool
		neutralCode FailureCode
		wantVerdict string
	}{
		{
			name:        "порт не отвечает — это адрес, а не имя",
			r:           Result{TCPOK: false, FailureCode: CodeTCPTimeout},
			wantVerdict: PathIP,
		},
		{
			name:        "порт закрыт по RST — тоже адрес",
			r:           Result{TCPOK: false, FailureCode: CodeTCPReset},
			wantVerdict: PathIP,
		},
		{
			name:        "TLS с нашим именем молчит, с нейтральным отвечает — режут имя",
			r:           Result{TCPOK: true, TLSOK: false, FailureCode: CodeTLSHandshakeTimeout},
			neutralOK:   true,
			wantVerdict: PathSNI,
		},
		{
			name:        "нейтральное имя получило alert — сервер жив, значит режут имя",
			r:           Result{TCPOK: true, TLSOK: false, FailureCode: CodeTLSReset},
			neutralCode: CodeTLSAlert,
			wantVerdict: PathSNI,
		},
		{
			name:        "молчит на любое имя — режут адрес",
			r:           Result{TCPOK: true, TLSOK: false, FailureCode: CodeTLSHandshakeTimeout},
			neutralCode: CodeTLSHandshakeTimeout,
			wantVerdict: PathIP,
		},
		{
			name:        "сервер сам ответил alert'ом на НАШЕ имя — это его политика",
			r:           Result{TCPOK: true, TLSOK: true, HTTPOK: &yes, FailureCode: CodeTLSAlert},
			wantVerdict: PathServer,
		},
		{
			name:        "сервер требует клиентский сертификат — тоже политика",
			r:           Result{TCPOK: true, TLSOK: true, HTTPOK: &yes, FailureCode: CodeMTLSRequired},
			wantVerdict: PathServer,
		},
		{
			name:        "проба прошла — классифицировать нечего",
			r:           Result{TCPOK: true, TLSOK: true},
			wantVerdict: "",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := c.r
			classifyPath(&r, c.neutralOK, c.neutralCode)
			if r.PathVerdict != c.wantVerdict {
				t.Fatalf("вердикт %q, ожидался %q (причина: %q)", r.PathVerdict, c.wantVerdict, r.PathReason)
			}
			if c.wantVerdict != "" && r.PathReason == "" {
				t.Fatalf("вердикт %q без объяснения — человеку нечего показать", r.PathVerdict)
			}
		})
	}
}
