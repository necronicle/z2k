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
	"net/netip"
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

// ConfigureV6 — IPv6-адрес аккаунта (/128) на туннеле: с ним WARP несёт и
// IPv6-трафик устройств. Адрес «уже есть» — не ошибка. Пустой адрес — IPv6
// у аккаунта нет, ничего не делаем.
func ConfigureV6(run Runner, name, addrV6 string) error {
	if addrV6 == "" {
		return nil
	}
	ip, err := netip.ParseAddr(addrV6)
	if err != nil || !ip.Is6() || ip.Is4In6() {
		return fmt.Errorf("bad IPv6 address %q", addrV6)
	}
	if out, err := run("ip", "-6", "addr", "add", ip.String()+"/128", "dev", name); err != nil {
		if !strings.Contains(out, "File exists") {
			return fmt.Errorf("ip -6 addr add: %s", firstLine(out, err))
		}
	}
	return nil
}

// RemoveV6 снимает прежний IPv6-адрес: у ключей WireGuard и MASQUE адреса
// разные, и при смене ключа старый на туннеле — чужой для Cloudflare.
func RemoveV6(run Runner, name, addrV6 string) {
	_, _ = run("ip", "-6", "addr", "del", addrV6+"/128", "dev", name)
}

// Проба IPv6 идёт с адреса аккаунта по своей таблице: маршрута в туннель у
// роутера нет, а таблица 989 — маршрутизация устройств, её снимает скрипт,
// когда туннель не готов, то есть ровно тогда, когда IPv6 и надо проверить.
const (
	ProbeTable6    = "990"
	probeRulePref6 = "89"
)

// RouteV6 — маршрут пробы IPv6: пакеты с адреса аккаунта уходят в туннель.
// Чужой трафик правило не задевает: с этим адресом источника ходит только
// сам движок (трафик устройств получает его уже после маршрутизации, NAT66).
func RouteV6(run Runner, name, addrV6 string) error {
	UnrouteV6(run, addrV6)
	if out, err := run("ip", "-6", "route", "replace", "default", "dev", name, "table", ProbeTable6); err != nil {
		return fmt.Errorf("ip -6 route: %s", firstLine(out, err))
	}
	if out, err := run("ip", "-6", "rule", "add", "pref", probeRulePref6, "from", addrV6+"/128", "table", ProbeTable6); err != nil {
		return fmt.Errorf("ip -6 rule: %s", firstLine(out, err))
	}
	return nil
}

// UnrouteV6 снимает правило и таблицу пробы; отсутствие — не ошибка.
func UnrouteV6(run Runner, addrV6 string) {
	for i := 0; i < 8; i++ {
		if _, err := run("ip", "-6", "rule", "del", "pref", probeRulePref6, "from", addrV6+"/128", "table", ProbeTable6); err != nil {
			break
		}
	}
	_, _ = run("ip", "-6", "route", "flush", "table", ProbeTable6)
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
