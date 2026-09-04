package classify

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

// ДВА ПРИВЕТСТВИЯ, А НЕ ОДНО.
//
// Один и тот же сайт разные устройства в доме открывают по-разному: свежий
// браузер идёт по TLS 1.3, старый телевизор на webOS — по TLS 1.2. Приветствия
// у них разные и по длине, и по набору расширений, и по тому, где внутри лежит
// имя. Коробка на них может реагировать по-разному, и почти наверняка реагирует:
// у 1.2 сертификат сервера виден открытым текстом, поэтому такие потоки часто
// обрабатываются отдельным правилом.
//
// Отсюда требование: стратегия, которую инструмент отдаёт человеку, обязана
// работать НА ОБОИХ. Измерить на 1.3 и промолчать про 1.2 значит починить
// макбук и оставить телевизор сломанным — причём человек об этом узнает не
// сразу и свяжет с чем угодно, кроме нашей строки.
//
// Поэтому после того, как дерево нашло приём, он ПЕРЕПРОВЕРЯЕТСЯ вторым
// приветствием. Это не второй полный прогон: гипотеза уже есть, проверяется
// ровно она.

// TLS12Trigger собирает приветствие СТАРОГО клиента: только TLS 1.2, без
// постквантовых ключей.
//
// Именно так выглядит хелло телевизора или другого железа, которому уже не
// прилетают обновления. Отличие от основного триггера не косметическое: там
// приветствие за полтора килобайта и само разъезжается на сегменты, здесь —
// втрое короче и укладывается в один.
func TLS12Trigger(sni string) (Trigger, error) {
	if sni == "" {
		return Trigger{}, errors.New("classify: пустой SNI")
	}
	client, server := net.Pipe()
	captured := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 8192)
		_ = server.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _ := io.ReadAtLeast(server, buf, 1)
		captured <- append([]byte(nil), buf[:n]...)
		_ = server.Close()
	}()
	c := tls.Client(client, &tls.Config{
		ServerName: sni,
		MinVersion: tls.VersionTLS12,
		MaxVersion: tls.VersionTLS12,
	})
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	_ = c.Handshake()
	_ = client.Close()

	select {
	case b := <-captured:
		if len(b) < 16 {
			return Trigger{}, fmt.Errorf("classify: приветствие 1.2 вышло длиной %d байт", len(b))
		}
		return Trigger{Name: "tls12:" + sni, Payload: b, Accept: acceptServerHello}, nil
	case <-time.After(3 * time.Second):
		return Trigger{}, errors.New("classify: не удалось собрать приветствие TLS 1.2")
	}
}

// verifyTLS12 перепроверяет найденный приём вторым приветствием.
//
// Возвращает: покрывает ли приём старых клиентов. nil — проверить не удалось
// (например, у триггера нет имени), и это отличается от «не покрывает».
func verifyTLS12(ctx context.Context, addr string, opt Options, res *Result,
	sni string, poisonName string) *bool {

	if sni == "" {
		return nil
	}
	tr12, err := TLS12Trigger(sni)
	if err != nil {
		return nil
	}

	// ЧЕРНОВИК, А НЕ ОБЩИЙ РЕЗУЛЬТАТ. Зонды пишут в Result не только трассу:
	// sweepPoisons перезаписывает вектор свойств (notePropsHit/Miss) и флаг
	// RawUsable. Гонять их по тому же res значило бы, что в отчёте окажутся
	// свойства коробки, измеренные на СТАРОМ приветствии, — а человек читает
	// их как результат основного замера. Поэтому перепроверка идёт в свой
	// Result, а наверх поднимаются только трасса и счётчик зондов.
	scratch := Result{}
	defer liftTrace(res, &scratch, "tls12:")

	// Сперва убеждаемся, что старое приветствие вообще режут. Если оно
	// проходит само по себе, проверять нечего: телевизору обход не нужен, и
	// объявлять «приём не покрывает 1.2» было бы враньём.
	base := measure(ctx, addr, tr12, opt, "как есть", nil, opt.WriteGap, &scratch)
	if base.pass == opt.Repeats {
		res.Reason += "; старое приветствие TLS 1.2 проходит и без обхода"
		return nil
	}

	switch res.Verdict {
	case VerdictPrefix, VerdictWholePacket:
		got := measure(ctx, addr, tr12, opt, "разрез", []int{res.SplitPos}, opt.WriteGap, &scratch)
		ok := got.pass == opt.Repeats
		return &ok
	case VerdictPoisonable:
		if poisonName == "" || opt.NoRaw || !rawSupported() {
			return nil
		}
		o := opt
		o.Only = poisonName
		_, hit := sweepPoisons(ctx, addr, tr12, o, &scratch)
		return &hit
	}
	return nil
}

// defaultJointBudget — сколько времени отводится поиску общего приёма.
//
// Число выбрано ЗАМЕРОМ, а не на глаз. www.instagram.com с роутера Марка,
// 04.09: без потолка поиск находит общий приём «fake-x7+seqovl-hello», но
// прогон занимает 3 м 45 с — сторож панели убивает замер на 180-й секунде.
// С потолком 45 с прогон укладывается в 1 м 8 с, но находки НЕ БЫВАЕТ: поиск
// сдаётся раньше, чем доходит до неё, и человек получает строку, не берущую
// телевизор, хотя общая существует.
//
// Потолок задачи в панели — пять минут, дерево до этого места тратит около
// двадцати секунд. Отсюда четыре минуты поиску и запас на сторожевой зазор.
//
// Такой бюджет допустим потому, что сюда доходят только домены старых
// устройств (см. LegacyDeviceDomain): ютуб и видеоотдача. Обычный домен
// заканчивается за секунды и в поиск не заходит вовсе.
const defaultJointBudget = 4 * time.Minute

// noteTLS12 дописывает в вердикт то, что человеку надо знать про старых
// клиентов. Молчание тут читалось бы как «покрывает», а это самый дорогой вид
// вранья: макбук чинится, телевизор нет, и связать одно с другим невозможно.
func noteTLS12(res *Result) {
	switch {
	case res.CoversTLS12 == nil:
		res.Reason += "; на старом TLS 1.2 приём не проверен"
	case *res.CoversTLS12:
		res.Reason += "; приём работает и на старом TLS 1.2"
	default:
		// Общего приёма не нашлось. Отдаём тот, что взял современное
		// приветствие: по нему ходит подавляющее большинство устройств, и
		// строка без покрытия телевизора всё равно полезнее пустоты. Но
		// умолчать про непокрытых нельзя — иначе человек будет искать поломку
		// в телевизоре.
		res.Reason += "; общего приёма для обоих приветствий не нашлось — выдана строка под " +
			"современный TLS 1.3, по нему ходит подавляющее большинство устройств; старые " +
			"(телевизоры, приставки) останутся без обхода"
	}
}

// legacyDeviceDomains — где старые устройства реально ходят по TLS 1.2.
//
// ПОЧЕМУ СПИСОК, А НЕ ВСЕ ДОМЕНЫ. Проверка приёма на старом приветствии и, тем
// более, поиск приёма, общего для обоих, стоят дорого: замер на роутере 04.09
// показал 3 секунды без них и 1 м 54 с с ними, а на www.instagram.com полный
// поиск занял 3 м 12 с. Платить это на каждом домене нельзя.
//
// А смысл платить есть ровно там, где за старым устройством сидит человек:
// телевизор, приставка, старый смарт-ТВ. Они ходят на ютуб — и на видеоотдачу
// googlevideo, — а не на форумы и не в соцсети. Для остальных доменов
// современного приветствия достаточно: по нему ходят браузеры и телефоны.
var legacyDeviceDomains = []string{
	"youtube.com",
	"youtu.be",
	"youtube-nocookie.com",
	"googlevideo.com",
	"ytimg.com",
	"ggpht.com",
}

// LegacyDeviceDomain — стоит ли для этого имени тратить время на подбор приёма,
// который возьмёт и старые устройства.
func LegacyDeviceDomain(sni string) bool {
	sni = strings.ToLower(strings.TrimSuffix(sni, "."))
	for _, d := range legacyDeviceDomains {
		if sni == d || strings.HasSuffix(sni, "."+d) {
			return true
		}
	}
	return false
}

// crossCheckTLS12 — единая точка: перепроверить найденный приём на старом
// приветствии, а если не прошёл — ИСКАТЬ общий, а не останавливаться на
// предупреждении.
//
// Цель инструмента — одна строка на оба приветствия. Предупреждение «на 1.2 не
// работает» честно, но это отчёт о неудаче, а не результат: у человека в доме
// и браузер, и телевизор, и строка нужна ему одна.
//
// Делается это ТОЛЬКО для доменов, куда ходят старые устройства (см.
// LegacyDeviceDomain). На остальных проверка молча пропускается: она стоит
// минуты, а телевизоров там нет.
func crossCheckTLS12(ctx context.Context, addr string, tr Trigger, opt Options, res *Result, poisonName string) {
	sni := triggerSNI(tr)
	if !LegacyDeviceDomain(sni) {
		return
	}
	res.CoversTLS12 = verifyTLS12(ctx, addr, opt, res, sni, poisonName)
	if res.CoversTLS12 != nil && !*res.CoversTLS12 {
		if joint, ok := findJointPoison(ctx, addr, tr, opt, res, sni, poisonName); ok {
			res.Strategy = strategyForPoison(joint)
			res.Reason += fmt.Sprintf("; приём «%s» берёт только новое приветствие, общий для обоих — «%s»",
				poisonName, joint.name)
			yes := true
			res.CoversTLS12 = &yes
		}
	}
	noteTLS12(res)
}

// findJointPoison ищет отравление, проходящее и на старом приветствии, и на
// новом.
//
// Перебор идёт ОДИН раз и по СТАРОМУ приветствию: оно жёстче, кандидатов на нём
// меньше. Каждая находка тут же проверяется на новом — прямо внутри перебора,
// через фильтр Options.accept. Не прошла — перебор продолжается с того же
// места, как будто гипотеза не сработала.
//
// Наивная версия перезапускала весь перебор на каждую отвергнутую находку.
// Замеры на роутере 04.09, www.instagram.com: перезапуском общий приём
// «fake-x7+seqovl-hello» находился за 3 м 45 с, одним проходом с фильтром — за
// 3 м 12 с при 99 зондах. Проход дешевле, но развилку он НЕ снимает: на трудном
// домене поиск всё равно не укладывается в панельный бюджет, и там мы честно
// откатываемся на приём под современное приветствие (см. noteTLS12). Полный
// поиск остаётся доступен вручную: classify -joint-budget 6m.
func findJointPoison(ctx context.Context, addr string, tr Trigger, opt Options, res *Result,
	sni, alreadyFailed string) (poison, bool) {

	if opt.NoRaw || !rawSupported() {
		return poison{}, false
	}
	tr12, err := TLS12Trigger(sni)
	if err != nil {
		return poison{}, false
	}
	budget := opt.JointBudget
	if budget <= 0 {
		budget = defaultJointBudget
	}
	ctx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()

	o := opt
	// Уже проверенное на новом приветствии и провалившееся там — не предлагать
	// снова: мы про него знаем ответ.
	if alreadyFailed != "" {
		o.Skip = map[string]bool{alreadyFailed: true}
	}
	o.accept = func(p poison) bool {
		if ctx.Err() != nil {
			return false
		}
		// Проверка находки на НОВОМ приветствии. Одна гипотеза, свой черновик:
		// свойства основного замера трогать нельзя.
		v := opt
		v.Only = p.name
		scratch := Result{}
		_, ok := sweepPoisons(ctx, addr, tr, v, &scratch)
		liftTrace(res, &scratch, "tls13:")
		return ok
	}

	scratch := Result{}
	hit, ok := sweepPoisons(ctx, addr, tr12, o, &scratch)
	liftTrace(res, &scratch, "tls12:")
	return hit, ok
}

// liftTrace поднимает трассу и счётчик зондов из черновика в общий результат,
// помечая шаги приветствием, на котором они сделаны.
func liftTrace(dst, src *Result, tag string) {
	for _, o := range src.Trace {
		if len(o.Probe) < len(tag) || o.Probe[:len(tag)] != tag {
			o.Probe = tag + o.Probe
		}
		dst.Trace = append(dst.Trace, o)
	}
	dst.Probes += src.Probes
}
