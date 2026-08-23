// Package tundev — туннельный интерфейс z2ktunN.
//
// Имя своё, не opkgtunN: NDM принимает только тип OpkgTun, а opkgtunN делят
// все Entware-туннели (usque, AWG, TrustTunnel) — конфликт имён со старыми
// установками был реальной жалобой. Интерфейс в NDM не регистрируется вовсе;
// NAT и MSS делаем сами (internal/nat).
package tundev

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"golang.zx2c4.com/wireguard/tun"
)

// Runner выполняет внешнюю команду; подменяется в тестах.
type Runner func(name string, args ...string) (string, error)

// Exec — Runner по умолчанию: exec.Command + CombinedOutput.
func Exec(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// Prefix — префикс имени интерфейса.
const Prefix = "z2ktun"

// PickName — первый z2ktunN, которого нет. exists — проверка существования netdev.
func PickName(exists func(string) bool) string {
	for n := 0; n < 16; n++ {
		name := fmt.Sprintf("%s%d", Prefix, n)
		if !exists(name) {
			return name
		}
	}
	return Prefix + "0"
}

// Exists — есть ли netdev с таким именем (через `ip link show`).
func Exists(run Runner, name string) bool {
	_, err := run("ip", "link", "show", "dev", name)
	return err == nil
}

// Create создаёт TUN-устройство с заданным именем и MTU.
func Create(name string, mtu int) (tun.Device, error) {
	return tun.CreateTUN(name, mtu)
}

// Configure — адрес /32, MTU, link up. Адрес «уже есть» — не ошибка.
func Configure(run Runner, name, addrV4 string, mtu int) error {
	if out, err := run("ip", "addr", "add", addrV4+"/32", "dev", name); err != nil {
		if !strings.Contains(out, "File exists") {
			return fmt.Errorf("ip addr add: %s", firstLine(out, err))
		}
	}
	if out, err := run("ip", "link", "set", "dev", name, "mtu", fmt.Sprint(mtu)); err != nil {
		return fmt.Errorf("ip link set mtu: %s", firstLine(out, err))
	}
	if out, err := run("ip", "link", "set", "dev", name, "up"); err != nil {
		return fmt.Errorf("ip link set up: %s", firstLine(out, err))
	}
	return nil
}

// Teardown опускает линк; само устройство исчезает при закрытии TUN.
func Teardown(run Runner, name string) error {
	if out, err := run("ip", "link", "set", "dev", name, "down"); err != nil {
		return errors.New(firstLine(out, err))
	}
	return nil
}

func firstLine(out string, err error) string {
	if out == "" {
		return err.Error()
	}
	if i := strings.IndexByte(out, '\n'); i > 0 {
		return out[:i]
	}
	return out
}
