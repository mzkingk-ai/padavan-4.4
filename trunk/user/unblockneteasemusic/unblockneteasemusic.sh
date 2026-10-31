#!/bin/sh
# UnblockNeteaseMusic - 网易云音乐解锁服务
# 基于 cnsilvan/UnblockNeteaseMusic (Go 版) 静态编译，配合 UPX 压缩
#
# 两种用法（由页面的「转发模式」控制）：
#   关闭  客户端手工把代理指向本机 5200(HTTP) / 5201(HTTPS)
#   开启  改写 /etc/hosts + dnsmasq 劫持 music.163.com，客户端零配置，
#         但需要把本脚本签发的 ca.crt 装到客户端作为受信任根证书

UNM_BIN="/usr/bin/UnblockNeteaseMusic"
UNM_PID="/var/run/unblockneteasemusic.pid"
UNM_LOG="/tmp/unblockneteasemusic.log"
UNM_DIR="/etc/storage/unblockneteasemusic"
UNM_CERT="$UNM_DIR/server.crt"
UNM_KEY="$UNM_DIR/server.key"
UNM_CA="$UNM_DIR/ca.crt"
UNM_CAKEY="$UNM_DIR/ca.key"
UNM_CSR="$UNM_DIR/server.csr"
UNM_EXT="$UNM_DIR/ext.cnf"

# 需要被转发/劫持的域名（对应 host/host.go 中的 HostDomain）
UNM_DOMAINS="music.163.com interface.music.163.com interface3.music.163.com"

unm_getip() {
	local ip

	ip=$(nvram get lan_ipaddr)
	[ -z "$ip" ] && ip=$(ip -4 addr show br0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
	echo "$ip"
}

unm_stop() {
	local pid p i

	pid=$(cat "$UNM_PID" 2>/dev/null)
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		logger -t "网易云解锁" "正在停止服务 (pid $pid)"
		kill "$pid" 2>/dev/null
		i=0
		while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
			i=$((i + 1))
			sleep 1
		done
		kill -9 "$pid" 2>/dev/null
	fi
	rm -f "$UNM_PID"

	# 兜底：按进程名清理（UPX 解包后进程名仍为 UnblockNeteaseMusic）
	for p in $(pidof UnblockNeteaseMusic 2>/dev/null); do
		kill -9 "$p" 2>/dev/null
	done

	unm_unhook_hosts
	unm_unhook_dns
}

# ---------------------------------------------------------------------------
# 证书
#   上游 createCertificate.sh 直接 genrsa/req/x509 串起来，在 OpenSSL 3.x 上会因
#   security level 拒绝 SHA1 而失败；这里显式启用 1.1.1 风格的认证级别，并分成
#   CA + 服务器证书两步，便于把 ca.crt 装到客户端作为根证书。
# ---------------------------------------------------------------------------
# 错误原因写在 UNM_LAST_ERR 里，页面/日志可直接展示，不用去翻完整日志
UNM_LAST_ERR=""

unm_check_cert() {
	UNM_LAST_ERR=""
	# 已有证书也要验一下：断电/写满 storage 时会留下 0 字节或破损文件，
	# 光看 -s 会放过它们，结果就是进程起来后才报 TLS 失败。
	if [ -s "$UNM_CERT" ] && [ -s "$UNM_KEY" ]; then
		if openssl x509 -in "$UNM_CERT" -noout >/dev/null 2>&1; then
			return 0
		fi
		logger -t "网易云解锁" "证书已损坏，重新签发"
		rm -f "$UNM_CERT" "$UNM_KEY"
	fi

	local sslconf="/etc_ro/openssl.cnf"
	if [ ! -f "$sslconf" ]; then
		sslconf="/etc/ssl/openssl.cnf"
		[ -f "$sslconf" ] || sslconf="/dev/null"
	fi

	mkdir -p "$UNM_DIR"

	if [ ! -s "$UNM_CA" ] || [ ! -s "$UNM_CAKEY" ]; then
		logger -t "网易云解锁" "正在生成 CA"
		openssl genrsa -out "$UNM_CAKEY" 2048 >>/dev/null 2>&1
		openssl req -x509 -new -nodes -key "$UNM_CAKEY" -sha256 -days 3650 \
			-config "$sslconf" -reqexts v3_ca \
			-subj "/C=CN/O=UnblockNeteaseMusic/CN=UnblockNeteaseMusic Root CA" \
			-out "$UNM_CA" >>/dev/null 2>&1
		openssl x509 -in "$UNM_CA" -noout -text >>/dev/null 2>&1 && {
			cat >"$UNM_EXT" <<-EOF
			basicConstraints=CA:FALSE
			keyUsage=digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
			extendedKeyUsage=serverAuth
			subjectAltName=DNS:music.163.com,DNS:*.music.163.com,DNS:*.music.126.net
			EOF
		}
	fi

	if [ -s "$UNM_CA" ] && [ -s "$UNM_CAKEY" ]; then
		logger -t "网易云解锁" "正在签发服务器证书"
		openssl genrsa -out "$UNM_KEY" 2048 >>/dev/null 2>&1
		openssl req -new -sha256 -key "$UNM_KEY" -out "$UNM_CSR" \
			-config "$sslconf" \
			-subj "/C=CN/O=UnblockNeteaseMusic/CN=*.music.163.com" \
			>>/dev/null 2>&1
		openssl x509 -req -sha256 -days 3650 -in "$UNM_CSR" \
			-CA "$UNM_CA" -CAkey "$UNM_CAKEY" -CAcreateserial \
			-extfile "$UNM_EXT" -out "$UNM_CERT" >>/dev/null 2>&1
		rm -f "$UNM_CSR"
	fi

	chmod 600 "$UNM_KEY" "$UNM_CAKEY" 2>/dev/null

	if [ -s "$UNM_CERT" ] && [ -s "$UNM_KEY" ]; then
		logger -t "网易云解锁" "证书就绪：$UNM_CERT"
		return 0
	fi

	# 证书是 HTTPS 端口的硬性前提。补救顺序：
	#   1. 降到无证书模式（-insecure），至少 HTTP 端口能继续用；
	#   2. 上游已把 panic 换成明确的中文报错 + 退出码 1，不会静默死掉。
	# 这两种兜底都不影响「转发模式」以外的手工代理用法。
	rm -f "$UNM_CERT" "$UNM_KEY"
	if [ -z "$(command -v openssl)" ]; then
		UNM_LAST_ERR="系统缺少 openssl，无法生成证书"
	else
		UNM_LAST_ERR="证书生成失败（openssl 可能不支持当前 sha256/配置文件）"
	fi
	logger -t "网易云解锁" "警告：$UNM_LAST_ERR，将以无证书模式启动（仅 HTTP 可用）"
	return 1
}

# ---------------------------------------------------------------------------
# /etc/hosts 转发
#   上游 mode=1 会自行解析 domains 并写 /etc/hosts，依赖其备份/恢复逻辑；
#   这里改由脚本托管，前缀统一打 mark，停止时按行清理，避免残留污染。
# ---------------------------------------------------------------------------
UNM_HOSTS_MARK="#unblockneteasemusic"

unm_hook_hosts() {
	local ip="$1"

	unm_unhook_hosts
	[ -z "$ip" ] && return 1
	echo "$UNM_HOSTS_MARK" >>/etc/hosts
	{
		for d in $UNM_DOMAINS; do
			echo "$ip $d $UNM_HOSTS_MARK"
		done
	} >>/etc/hosts
	logger -t "网易云解锁" "已把网易云音乐域名指向 $ip"
}

unm_unhook_hosts() {
	[ -f /etc/hosts ] || return 0
	if grep -q "$UNM_HOSTS_MARK" /etc/hosts 2>/dev/null; then
		grep -v "$UNM_HOSTS_MARK" /etc/hosts >/etc/hosts.unm
		cat /etc/hosts.unm >/etc/hosts
		rm -f /etc/hosts.unm
		logger -t "网易云解锁" "已还原 /etc/hosts"
	fi
}

# 客户端查询 music.163.com 时必须拿到本机 IP，才会去连本机 443 上的代理。
# 这里写的是持久化的用户配置文件，rc 启动 dnsmasq 时通过
# conf-file=/etc/storage/dnsmasq/dnsmasq.conf 加载（与 SmartDNS 同一份文件，
# 因此两边都按行增删，互不覆盖）。
UNM_DNSMASQ_CONF="/etc/storage/dnsmasq/dnsmasq.conf"
UNM_DNS_MARK="#unblockneteasemusic"

unm_hook_dns() {
	local ip="$1"

	[ -z "$ip" ] && return 1
	mkdir -p "$(dirname "$UNM_DNSMASQ_CONF")"
	[ -f "$UNM_DNSMASQ_CONF" ] || : >"$UNM_DNSMASQ_CONF"

	unm_unhook_dns
	# 每一行都要带 mark：dnsmasq 的行内注释即 '#'，所以 mark 必须放在行尾，
	# 关闭时靠它把整块规则一次删干净，不会残留 address= 行。
	{
		echo "address=/music.163.com/$ip $UNM_DNS_MARK"
		echo "address=/interface.music.163.com/$ip $UNM_DNS_MARK"
		echo "address=/interface3.music.163.com/$ip $UNM_DNS_MARK"
	} >>"$UNM_DNSMASQ_CONF"
	logger -t "网易云解锁" "已写入 DNS 劫持规则（$ip），重启 DNS 服务后生效"
	return 0
}

unm_unhook_dns() {
	[ -f "$UNM_DNSMASQ_CONF" ] || return 0
	if grep -q "$UNM_DNS_MARK" "$UNM_DNSMASQ_CONF" 2>/dev/null; then
		grep -v "$UNM_DNS_MARK" "$UNM_DNSMASQ_CONF" >"$UNM_DNSMASQ_CONF.unm"
		cat "$UNM_DNSMASQ_CONF.unm" >"$UNM_DNSMASQ_CONF"
		rm -f "$UNM_DNSMASQ_CONF.unm"
	fi
}

unm_start() {
	local port sslport source mode extra ip args pid

	if [ ! -x "$UNM_BIN" ]; then
		logger -t "网易云解锁" "错误：找不到可执行文件 $UNM_BIN"
		return 1
	fi

	unm_stop

	port=$(nvram get wyybin_port)
	sslport=$(nvram get wyybin_sslport)
	source=$(nvram get wyybin_source)
	mode=$(nvram get wyybin_mode)
	args=$(nvram get wyybin_extra)

	[ -z "$port" ] && port=5200
	[ -z "$sslport" ] && sslport=5201
	# 音源默认值 pyncmd:kuwo：pyncmd 用网易 songId 直接换地址、不猜原唱，
	# 覆盖不到的歌（实测约 17%）再落到酷我换源。老的 wyybin_source 值原样保留，
	# 所以升级固件不会改掉用户已经选好的音源。
	[ -z "$source" ] && source=pyncmd:kuwo
	[ -z "$mode" ] && mode=0

	# 配置里只写了换源音源（升级前保存的旧值）时，自动在队首补上 pyncmd，
	# 让老配置也享受到「不猜原唱」这条更稳的通道。
	# 分隔符必须是冒号：上游 config.ValidParams 用 strings.Split(*Source, ":") 拆分，
	# 写管线或逗号会被当成一个整体名字（实测 providers=["pyncmd|kuwo"]，一个源都没注册上）。
	# 先归一再判断，顺序不能反：老配置存的是竖线，先判断会误以为没写 pyncmd。
	source=$(echo "$source" | tr '|' ':')
	case ":$source:" in
		*":pyncmd:"*) : ;;
		*) source="pyncmd:$source" ;;
	esac

	# 上游参数：-a 监听地址 -p HTTP 端口 -sp HTTPS 端口 -o 音源
	#           -c/-k 证书 -m 运行模式(1=hosts) -l 日志文件
	#           -ms 最低匹配分（低于此分的搜索结果一律丢弃，宁缺勿错）
	# 注意：mode 固定为 0（API/代理），hosts 改由本脚本托管，避免上游
	#       自动重建 /etc/hosts 时与系统自身的主机名记录互相覆盖。
	args="-a 0.0.0.0 -p $port -sp $sslport -o $source -m 0 -l $UNM_LOG"

	unm_check_cert
	if [ $? -eq 0 ]; then
		args="$args -c $UNM_CERT -k $UNM_KEY"
	else
		# 证书不可用时不传 -c/-k，改用 -insecure 让 TLS 端口按明文监听，
		# 避免进程因为缺证书直接退出（上游原先在这里 panic）
		args="$args -insecure"
	fi

	# 页面上的「匹配阈值」：0 表示不过滤（回到上游行为），留空用默认 0.75
	ms=$(nvram get wyybin_minscore)
	[ -z "$ms" ] && ms=0.75
	case "$ms" in
		0|1|0.*|1.0|1.00) args="$args -ms $ms" ;;
		*) logger -t "网易云解锁" "忽略非法匹配阈值 wyybin_minscore=$ms，使用默认 0.75"; args="$args -ms 0.75" ;;
	esac

	# 「-e」（endPoint 模式）不再使用：它把音源地址包装成
	#   https://music.163.com/unblockmusic/<真实地址>
	# 依赖客户端把 music.163.com 解析到本机，一旦 hosts 失效整条链路就断。
	# 现在的做法是代理进程自己接住 /unblockmusic/ 请求并直接转发音源，
	# 客户端拿到的是普通直链，链路不再有回环依赖。
	# 若确实需要旧行为，在页面「额外参数」里填 -e 即可覆盖。

	# 额外参数由用户在页面里填写，优先级最高（可覆盖上面任何一项）
	extra=$(nvram get wyybin_extra)
	[ -n "$extra" ] && args="$args $extra"

	logger -t "网易云解锁" "正在启动：$UNM_BIN $args"
	$UNM_BIN $args >>"$UNM_LOG" 2>&1 &
	pid=$!
	echo "$pid" >"$UNM_PID"

	sleep 2
	if ! kill -0 "$pid" 2>/dev/null; then
		# 上游新版会在日志里打「启动失败：<原因>」，这里抓出来单独记一条，
		# 免得用户只能看到一大堆 banner 之后才发现进程没了
		reason=$(grep -a "启动失败" "$UNM_LOG" 2>/dev/null | tail -n 1)
		[ -z "$reason" ] && reason=$(tail -n 1 "$UNM_LOG" 2>/dev/null)
		logger -t "网易云解锁" "启动失败（进程已退出）：$reason"
		rm -f "$UNM_PID"
		return 1
	fi

	logger -t "网易云解锁" "启动成功，HTTP $port / HTTPS $sslport，音源 $source"

	# mode=1 为转发模式：把音乐域名指向本机，客户端无需任何设置
	ip=$(unm_getip)
	if [ "$mode" = "1" ] || [ "$mode" = "2" ]; then
		unm_hook_hosts "$ip"
		unm_hook_dns "$ip"
	fi

	return 0
}

case "$1" in
start)
	unm_start
	;;
stop)
	unm_stop
	;;
restart)
	unm_stop
	unm_start
	;;
status)
	if pidof UnblockNeteaseMusic >/dev/null 2>&1; then
		echo "running"
	else
		echo "stopped"
	fi
	;;
cert)
	unm_check_cert && echo "$UNM_CA"
	;;
*)
	echo "Usage: $0 {start|stop|restart|status|cert}"
	exit 1
	;;
esac

exit 0
