//go:build !linux

package voiceprobe

import (
	"errors"
	"net"
	"strconv"
)

// Target — куда слать зонд.
type Target struct {
	IP      net.IP
	Port    int
	Packets int
}

func (t Target) String() string { return net.JoinHostPort(t.IP.String(), strconv.Itoa(t.Port)) }

// ConntrackPath объявлен и здесь, чтобы код собирался на маке.
var ConntrackPath = ""

// Вне Linux таблицы соединений ядра нет, а значит нет и способа узнать, куда
// идёт разговор. Возвращаем ошибку, а не пустой список: пустой список означал
// бы «разговора нет», и человек искал бы проблему в Дискорде.
func FindVoiceTargets() ([]Target, error) {
	return nil, errors.New("voiceprobe: замер голоса работает только на роутере")
}
