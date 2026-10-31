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
UNM_CSR="$UNM_DIR/server.csr"
UNM_EXT="$UNM_DIR/ext.cnf"

# 证书位置由页面的两个输入框（nvram: wyybin_cert / wyybin_key）决定，
# 每项都支持三种写法：
#   ① 留空              → 用默认值 <UNM_DIR>/xxx，即老版本的行为
#   ② 绝对路径          → 直接使用该文件，例如 /media/UDISK/unm/ca.crt
#   ③ 只写文件名的相对路径 → 视为相对于 UNM_DIR，例如 unm/ca.crt
# 证书放在 U 盘上是最实用的用法：U 盘挂载点 /media/<分区标签> 不随固件升级
# 被清空，所以刷机后 CA 仍然是同一套，客户端不用重新安装。
# 注意：必须以证书文件（*.crt，CA 或带私钥的合并证书）为单位，不要写目录。
unm_abspath() {
	case "$1" in
		/*) echo "$1" ;;
		*) echo "$UNM_DIR/$1" ;;
	esac
}

unm_resolve_cert_paths() {
	local c k

	c=$(nvram get wyybin_cert)
	k=$(nvram get wyybin_key)

	[ -n "$c" ] || c="$UNM_DIR/server.crt"
	UNM_CERT=$(unm_abspath "$c")

	# 私钥留空时取与证书同名的 .key（server.crt → server.key）。
	# 不要在这里去猜 ca.key：CA 私钥只在签服务器证书时才用，
	# 拿它当服务器私钥既配不上证书，也会在签发时把 CA 私钥覆盖掉。
	if [ -n "$k" ]; then
		UNM_KEY=$(unm_abspath "$k")
	else
		UNM_KEY="${UNM_CERT%.crt}.key"
	fi

	# 服务器证书与私钥指向同一文件 = 自签合并证书（crt 里同时含私钥），
	# 此时它自己充任 CA，CA 私钥也复用这一份。
	if [ "$UNM_CERT" = "$UNM_KEY" ]; then
		UNM_CA="$UNM_CERT"
		UNM_CAKEY="$UNM_KEY"
		return 0
	fi

	# 常规布局：CA 与服务器证书同目录，名为 ca.crt / ca.key。
	# 注意不能拿「ca.crt 是否存在」来决定 CA 路径，否则首次生成时
	# CA 会被写到 ca.key 上（路径推导一致，但两个变量会互相覆盖）。
	UNM_CA="$(dirname "$UNM_CERT")/ca.crt"
	UNM_CAKEY="$(dirname "$UNM_CERT")/ca.key"
}

# 已有证书「还能不能接着用」的统一判定。
# 复用优先是这套机制的核心：证书一旦签好就不再重签，客户端装过一次 CA 之后
# 便一直有效。只有文件缺失、无法解析、核对不上或者 30 天内到期时才重新生成。
# -checkend 30 天：留出余量，避免证书恰好在下次重启的边界上失效。
unm_cert_usable() {
	[ -s "$UNM_CERT" ] && [ -s "$UNM_KEY" ] || return 1
	openssl x509 -in "$UNM_CERT" -noout >/dev/null 2>&1 || return 1
	openssl x509 -in "$UNM_CERT" -noout -checkend 2592000 >/dev/null 2>&1
}

# 服务器证书是否确实由这把 CA 私钥对应的 CA 签发。
# 用来排掉「CA 换了、服务器证书还是旧的」这种客户端必然报错的半残状态。
unm_cert_matches_ca() {
	[ -s "$UNM_CA" ] && [ -s "$UNM_CAKEY" ] || return 1
	[ -s "$UNM_CERT" ] && [ -s "$UNM_KEY" ] || return 1
	# 证书与私钥是否配对由 unm_key_matches_cert 单独判断，这里只看签发链
	openssl verify -CAfile "$UNM_CA" "$UNM_CERT" >/dev/null 2>&1
}

# 私钥与证书是否为同一对：拿私钥算出公钥，与证书里的公钥比对
unm_key_matches_cert() {
	local cert_pub key_pub

	cert_pub=$(openssl x509 -in "$UNM_CERT" -noout -pubkey 2>/dev/null) || return 1
	key_pub=$(openssl pkey -in "$UNM_KEY" -pubout 2>/dev/null) || return 1
	[ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ]
}

unm_gen_ca() {
	# CA 生成必须自带扩展段：老写法靠 /dev/null 或固件自带的 openssl.cnf
	# 提供 v3_ca，在 OpenSSL 3.x 上会直接报
	#   Error checking x509 extension section v3_ca
	# 所以把 basicConstraints 写进独立配置，不再依赖系统配置。
	local cfg="$UNM_DIR/dn.cnf"

	cat >"$cfg" <<-EOF
		[req]
		distinguished_name = dn
		prompt = no
		[dn]
		[v3_ca]
		basicConstraints = critical,CA:TRUE
		keyUsage = critical,keyCertSign,cRLSign
		subjectKeyIdentifier = hash
	EOF

	mkdir -p "$(dirname "$UNM_CAKEY")" 2>/dev/null
	openssl genrsa -out "$UNM_CAKEY" 2048 >>/dev/null 2>&1 || return 1
	openssl req -x509 -new -nodes -key "$UNM_CAKEY" -sha256 -days 3650 \
		-config "$cfg" -reqexts v3_ca \
		-subj "/C=CN/O=UnblockNeteaseMusic/CN=UnblockNeteaseMusic Root CA" \
		-out "$UNM_CA" >>/dev/null 2>&1 || return 1
	rm -f "$cfg"
	openssl x509 -in "$UNM_CA" -noout >/dev/null 2>&1
}

unm_gen_server_cert() {
	local cfg="$UNM_DIR/ext.cnf"

	# 192.168.3.1 / 172.16.0.1 只是兜底：正常走 DNS 劫持时起作用的是那几个域名
	cat >"$cfg" <<-EOF
		basicConstraints=CA:FALSE
		keyUsage=digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
		extendedKeyUsage=serverAuth
		subjectAltName=DNS:music.163.com,DNS:*.music.163.com,DNS:*.music.126.net,IP:192.168.3.1,IP:172.16.0.1
	EOF

	mkdir -p "$(dirname "$UNM_KEY")" 2>/dev/null
	openssl genrsa -out "$UNM_KEY" 2048 >>/dev/null 2>&1 || return 1
	openssl req -new -sha256 -key "$UNM_KEY" -out "$UNM_CSR" \
		-subj "/C=CN/O=UnblockNeteaseMusic/CN=music.163.com" \
		>>/dev/null 2>&1 || return 1
	# -CAserial 放在服务器证书旁边（与 CA 文件同目录），跟着整套证书一起搬走
	local srl="$(dirname "$UNM_CERT")/ca.srl"
	openssl x509 -req -sha256 -days 3650 -in "$UNM_CSR" \
		-CA "$UNM_CA" -CAkey "$UNM_CAKEY" \
		-CAserial "$srl" -CAcreateserial \
		-extfile "$cfg" -out "$UNM_CERT" >>/dev/null 2>&1
	rm -f "$UNM_CSR" "$cfg"
	[ -s "$UNM_CERT" ]
}

unm_check_cert() {
	local cdir kdir

	UNM_LAST_ERR=""
	unm_resolve_cert_paths
	cdir=$(dirname "$UNM_CERT")
	kdir=$(dirname "$UNM_KEY")

	# ---- ① 已有且可用的证书：原样复用，一个字节都不动 ----
	if unm_cert_usable; then
		if unm_cert_matches_ca && unm_key_matches_cert; then
			logger -t "网易云解锁" "证书可复用：$UNM_CERT（到期 $(openssl x509 -in "$UNM_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)）"
			return 0
		fi
		logger -t "网易云解锁" "证书与私钥/CA 不匹配，准备重新签发"
	else
		logger -t "网易云解锁" "证书缺失、损坏或 30 天内到期，准备生成"
	fi

	# ---- ② 目标目录必须可写（U 盘没挂载是最常见的原因）----
	[ -d "$cdir" ] || mkdir -p "$cdir" 2>/dev/null
	[ -d "$kdir" ] || mkdir -p "$kdir" 2>/dev/null
	if [ ! -w "$cdir" ]; then
		UNM_LAST_ERR="证书目录不可写：$cdir（U 盘是否已挂载？）"
		logger -t "网易云解锁" "警告：$UNM_LAST_ERR"
		return 1
	fi
	if [ ! -w "$kdir" ]; then
		UNM_LAST_ERR="私钥目录不可写：$kdir（U 盘是否已挂载？）"
		logger -t "网易云解锁" "警告：$UNM_LAST_ERR"
		return 1
	fi

	if [ -z "$(command -v openssl)" ]; then
		UNM_LAST_ERR="系统缺少 openssl，无法生成证书"
		logger -t "网易云解锁" "警告：$UNM_LAST_ERR，将以无证书模式启动（仅 HTTP 可用）"
		return 1
	fi

	# ---- ③ CA 还能用吗？能用就只重签服务器证书，客户端无需重装 CA ----
	if [ -s "$UNM_CA" ] && [ -s "$UNM_CAKEY" ] && \
		openssl x509 -in "$UNM_CA" -noout -checkend 2592000 >/dev/null 2>&1 && \
		openssl rsa -in "$UNM_CAKEY" -check -noout >/dev/null 2>&1; then
		logger -t "网易云解锁" "仅重新签发服务器证书（沿用现有 CA，客户端无需重装）"
		if unm_gen_server_cert; then
			chmod 600 "$UNM_KEY" "$UNM_CAKEY" 2>/dev/null
			logger -t "网易云解锁" "证书续签完成：$UNM_CERT"
			return 0
		fi
	fi

	# ---- ④ CA 也不可用：整套重签 ----
	logger -t "网易云解锁" "正在生成 CA（自签根证书，需安装到客户端）"
	if ! unm_gen_ca; then
		UNM_LAST_ERR="CA 生成失败（openssl 可能不支持当前 sha256）"
		logger -t "网易云解锁" "警告：$UNM_LAST_ERR"
		rm -f "$UNM_CA" "$UNM_CAKEY"
		return 1
	fi

	logger -t "网易云解锁" "正在签发服务器证书"
	if unm_gen_server_cert; then
		chmod 600 "$UNM_KEY" "$UNM_CAKEY" 2>/dev/null
		logger -t "网易云解锁" "证书就绪：$UNM_CERT"
		return 0
	fi

	UNM_LAST_ERR="证书签发失败（openssl 可能不支持当前 sha256/配置文件）"
	logger -t "网易云解锁" "警告：$UNM_LAST_ERR，将以无证书模式启动（仅 HTTP 可用）"
	rm -f "$UNM_CERT" "$UNM_KEY"
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

# ---------------------------------------------------------------------------
# 开关型参数（bu/ba/lv/sef/wl）
#   每个都由页面上独立的开关控制。缺省（nvram 里没有这个键）一律按「开启」处理。
#   注意 -bv 不是「每次启动都走默认分支」：页面提交时 draft 会照着默认值
#   把缺失的键补成 "1" 写进 nvram，所以它只在升级后第一次启动时生效。
# ---------------------------------------------------------------------------
unm_flag() {
	local opt="$1" key="$2" val

	val=$(nvram get "$key")
	[ "$val" = "0" ] && return 0
	echo "$opt"
}

# ---------------------------------------------------------------------------
# 音源过滤：QQ 音源默认关闭
#   QQ 的取址接口对未开通绿钻的账号一律返回 104003 / purl 为空，
#   硬塞进音源列表只会每次多走一次无效请求，所以默认不放进去。
#   用户在页面勾选「启用 QQ 音源」后 wyybin_qq_enable=1 才保留。
# ---------------------------------------------------------------------------
unm_filter_sources() {
	local src="$1" item out=""
	local qq_enable

	qq_enable=$(nvram get wyybin_qq_enable)
	[ "$qq_enable" = "1" ] && { echo "$src"; return 0; }

	# 按冒号逐项过滤后重新拼接，保持原有的先后顺序
	local IFS=':'
	for item in $src; do
		[ -z "$item" ] && continue
		[ "$item" = "qq" ] && continue
		if [ -z "$out" ]; then out="$item"; else out="$out:$item"; fi
	done
	echo "$out"
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

	# QQ 音源默认不启用（见 unm_filter_sources）。过滤放在补 pyncmd 之后，
	# 保证用户选的顺序不变，只是把 qq 这一项摘掉。
	source=$(unm_filter_sources "$source")
	[ -z "$source" ] && source=pyncmd

	# 上游参数：-a 监听地址 -p HTTP 端口 -sp HTTPS 端口 -o 音源
	#           -c/-k 证书 -m 运行模式(1=hosts) -l 日志文件
	#           -ms 最低匹配分（低于此分的搜索结果一律丢弃，宁缺勿错）
	# 注意：mode 固定为 0（API/代理），hosts 改由本脚本托管，避免上游
	#       自动重建 /etc/hosts 时与系统自身的主机名记录互相覆盖。
	args="-a 0.0.0.0 -p $port -sp $sslport -o $source -m 0 -l $UNM_LOG"

	# -wl 把每个请求和响应正文都打进日志，单条几 KB 到几十 KB，放开了写
	# 十几分钟就能把 /tmp（内存盘）填满，进而拖垮 smartdns、dnsmasq 这些
	# 同样写 /tmp 的进程。所以只保留最近 8MB 的尾部：
	# 超过 10MB 就截到最近 8MB，而不是直接清空，方便回看刚才发生了什么。
	local loglimit=8388608
	local sz

	if [ -f "$UNM_LOG" ]; then
		sz=$(wc -c <"$UNM_LOG" 2>/dev/null)
		[ -z "$sz" ] && sz=0
		if [ "$sz" -gt $((loglimit + loglimit / 4)) ]; then
			cp "$UNM_LOG" "$UNM_LOG.old" 2>/dev/null
			tail -c "$loglimit" "$UNM_LOG.old" >"$UNM_LOG" 2>/dev/null
			rm -f "$UNM_LOG.old"
		fi
	fi


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

	# ------------------------------------------------------------------
	# 功能开关：默认全部开启，页面上每个开关独立控制，互不影响。
	#   -bu 屏蔽升级提示   -ba 去广告   -lv 本地伪 VIP
	#   -sef 解锁音效      -wl 打印请求全文
	# 只追加到 args 末尾，不参与「额外参数」的拼接，因此用户在额外参数
	# 里写的同名字段依然排在最末，可以覆盖这里的默认值。
	# ------------------------------------------------------------------
	args="$args $(unm_flag -bu wyybin_bu) $(unm_flag -ba wyybin_ba) $(unm_flag -lv wyybin_lv) $(unm_flag -sef wyybin_sef) $(unm_flag -wl wyybin_wl)"

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
	# 输出生效的证书/私钥路径与状态，页面「证书状态」用
	unm_resolve_cert_paths
	if unm_check_cert; then
		echo "OK|cert=$UNM_CERT|key=$UNM_KEY"
		echo "END=$(openssl x509 -in "$UNM_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
		echo "SUBJ=$(openssl x509 -in "$UNM_CERT" -noout -subject 2>/dev/null | sed 's/^subject=//')"
	else
		echo "ERR|$UNM_LAST_ERR"
	fi
	;;
regen)
	# 强制重签：删掉现有证书后按同样的流程重建。
	# 这是唯一会更换 CA 的入口，页面上的按钮带二次确认。
	unm_resolve_cert_paths
	if [ -n "$UNM_CERT" ] && [ "$UNM_CERT" != "$UNM_KEY" ]; then
		rm -f "$UNM_CERT" "$UNM_CA" "$UNM_CAKEY" "$UNM_KEY" "$UNM_CSR" "$UNM_EXT"
	else
		# 合并式自签证书（证书=私钥同一文件）不能先删，否则私钥也没了
		rm -f "$UNM_CERT" "$UNM_CSR" "$UNM_EXT"
	fi
	logger -t "网易云解锁" "按页面请求强制重新生成证书"
	if unm_check_cert; then
		echo "OK|cert=$UNM_CERT|key=$UNM_KEY"
		echo "END=$(openssl x509 -in "$UNM_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
		echo "SUBJ=$(openssl x509 -in "$UNM_CERT" -noout -subject 2>/dev/null | sed 's/^subject=//')"
	else
		echo "ERR|$UNM_LAST_ERR"
	fi
	# 证书换了之后，正在跑的进程仍捏着旧证书，需要重启
	if [ "$(pidof UnblockNeteaseMusic)" ] && [ "$(nvram get wyybin_enable)" = "1" ]; then
		unm_stop
		unm_start >/dev/null 2>&1
	fi
	;;
*)
	echo "Usage: $0 {start|stop|restart|status|cert|regen}"
	exit 1
	;;
esac

exit 0
