#!/bin/sh
# UnblockNeteaseMusic - 网易云音乐解锁服务
# 基于 cnsilvan/UnblockNeteaseMusic (Go 版) 静态编译。
# 构建约束只有一条：必须用 go1.22 编译（go1.23+ 的 lock_spinbit 在 MT7621 上
# 让 futex 返回 -89，一启动就 SIGSEGV），UPX 压缩本身没有问题，见 Makefile。
#
# 两种用法（由页面的「转发模式」控制）：
#   关闭  客户端手工把代理指向本机 5200(HTTP) / 5201(HTTPS)
#   开启  往 dnsmasq 用户配置写 address= 规则，把 music.163.com 等域名
#         解析到本机，客户端零配置；但需要把本脚本签发的 ca.crt 装到
#         客户端作为受信任根证书

UNM_BIN="/usr/bin/UnblockNeteaseMusic"
# /proc/<pid>/comm 被内核截断到 15 字节。旧二进制叫 UnblockNeteaseMusic（19 字节）
# 时被截成 UnblockNeteaseM，pidof 按原名仍能匹配；但 U 盘那份文件名多了 .new，
# 截断后变成 UnblockNeteaseM.new，pidof 用原名就找不到它，于是 stop/status/watch
# 全部失灵、cron 守护还会重复拉起抢端口。改成直接匹配 /proc 的命令行。
UNM_PROG="UnblockNeteaseMusic"
UNM_PID="/var/run/unblockneteasemusic.pid"
UNM_LOG="/tmp/unblockneteasemusic.log"
# 守护冷却时间戳。放 /tmp 是故意的：重启后清零，第一次 cron 就能正常拉起
UNM_WATCH_STAMP="/tmp/unblockneteasemusic.watch"
UNM_DIR="/etc/storage/unblockneteasemusic"
# 出厂证书套装放在 romfs 里，由 /sbin/mtd_storage.sh 的 func_fill 在首次开机时
# 拷到 $UNM_DIR（见 user/unblockneteasemusic/Makefile 的 romfs 段）。
# 这里自己也认这个目录：/etc/storage 被用户清空过、或者目标目录被删掉时，
# 脚本可以从这里再拷一份，免得又跑一次 openssl 生成一套新 CA。
UNM_DEFAULT_CERT_DIR="/etc/unm-cert-default"
# 证书相关文件的实际路径由 unm_resolve_cert_paths 按 wyybin_cert 计算，
# 这里只给默认值兜底（命令分发前一定会先调用一次）。
UNM_CSR="$UNM_DIR/server.csr"
UNM_EXT="$UNM_DIR/ext.cnf"

# 本机 LAN 地址，用于转发模式把音乐域名指过来
unm_getip() {
	local ip

	ip=$(nvram get lan_ipaddr)
	[ -z "$ip" ] && ip=$(ip -4 addr show br0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
	echo "$ip"
}

# ---------------------------------------------------------------------------
# 守护 crontab 的增删
#   为什么不用 /sbin/check_crontab.sh：它只认 /usr/bin/<脚本名> 这种调用形式，
#   而且只增不删，服务关掉后那行还留着，每 5 分钟醒来白白 fork 一次。
#   这里自己管一行带标记的规则，加和删都幂等。
#   crond 每 60 秒重新读一次 crontabs 目录，所以增删都不需要重启 crond。
# ---------------------------------------------------------------------------
UNM_CRON_TAG="#unblockneteasemusic-watch"
UNM_CRON_FILE="/etc/storage/cron/crontabs/admin"

unm_cron_add() {
	mkdir -p /etc/storage/cron/crontabs 2>/dev/null
	[ -f "$UNM_CRON_FILE" ] || : >"$UNM_CRON_FILE"
	if grep -q "$UNM_CRON_TAG" "$UNM_CRON_FILE" 2>/dev/null; then
		return 0
	fi
	echo "*/5 * * * * /usr/bin/unblockneteasemusic.sh watch >/dev/null 2>&1 $UNM_CRON_TAG" >>"$UNM_CRON_FILE"
	chmod 600 "$UNM_CRON_FILE" 2>/dev/null
	logger -t "网易云解锁" "已加入守护任务（每 5 分钟检查一次）"
}

unm_cron_del() {
	[ -f "$UNM_CRON_FILE" ] || return 0
	if grep -q "$UNM_CRON_TAG" "$UNM_CRON_FILE" 2>/dev/null; then
		grep -v "$UNM_CRON_TAG" "$UNM_CRON_FILE" >"$UNM_CRON_FILE.unm"
		cat "$UNM_CRON_FILE.unm" >"$UNM_CRON_FILE"
		rm -f "$UNM_CRON_FILE.unm"
		logger -t "网易云解锁" "已移除守护任务"
	fi
}

# 列出所有 UNM 进程：优先命令行匹配（不受 comm 15 字节截断影响），
# 再并上 pidof 的结果（覆盖 UPX 解包等异常情形）。输出已排序去重。
unm_pids() {
	{
		for d in /proc/[0-9]*; do
			[ -r "$d/cmdline" ] || continue
			if tr '\0' ' ' <"$d/cmdline" 2>/dev/null | grep -q "$UNM_PROG"; then
				basename "$d"
			fi
		done
		pidof "$UNM_PROG" 2>/dev/null | tr ' ' '\n'
	} | grep -v '^$' | sort -u
}

# 停止服务：先按 pid 文件优雅退出，再用进程名兜底，最后清理 DNS 劫持。
# 清理劫持是必须的，否则 failover 后域名仍指向本机、而服务已停，客户端会连不上。
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

	# 兜底：按命令行清理（见上面的 UNM_PROG 说明）
	for p in $(unm_pids); do
		kill -9 "$p" 2>/dev/null
	done

	unm_unhook_dns
	# 守护任务跟着服务一起走：服务停了还留着一行 cron，
	# 只会每 5 分钟把已经关掉的服务又拉起来，与用户的意图相反。
	unm_cron_del
}

# 证书目录由页面的一个输入框（nvram: wyybin_cert）决定，默认就是
# /etc/storage/unblockneteasemusic —— 也就是 /etc/storage 持久化分区，
# 重启、刷固件都不会丢。可以改成别的目录（例如 /media/UDISK/unm），
# 改完只要那里有完整的一套文件就能直接用，没有则自动生成一套。
# 目录里固定使用这 4 个文件名，全部有效期为 3650 天：
#   ca.crt      自签根证书，装到客户端
#   ca.key      根证书私钥
#   server.crt  服务器证书（由 ca.key 签发）
#   server.key  服务器证书私钥
# ca.srl / server.csr / ext.cnf 是签发过程中的临时文件，可删。
unm_abspath() {
	case "$1" in
		/*) echo "$1" ;;
		*) echo "$UNM_DIR/$1" ;;
	esac
}

unm_resolve_cert_paths() {
	local d

	d=$(nvram get wyybin_cert)
	[ -n "$d" ] || d="$UNM_DIR"
	UNM_CERT_DIR=$(unm_abspath "$d")
	# 去掉尾部多余的斜杠，避免拼出 //ca.crt 这种路径
	while [ "$UNM_CERT_DIR" != "/" ] && [ "${UNM_CERT_DIR%/}" != "$UNM_CERT_DIR" ]; do
		UNM_CERT_DIR="${UNM_CERT_DIR%/}"
	done

	UNM_CA="$UNM_CERT_DIR/ca.crt"
	UNM_CAKEY="$UNM_CERT_DIR/ca.key"
	UNM_CERT="$UNM_CERT_DIR/server.crt"
	UNM_KEY="$UNM_CERT_DIR/server.key"
	# 临时文件也跟着证书目录走：默认目录只读（空间满/写保护）时，
	# 把证书指到 U 盘依然能生成，不会因为写不进 dn.cnf 而失败。
	UNM_CSR="$UNM_CERT_DIR/server.csr"
	UNM_EXT="$UNM_CERT_DIR/ext.cnf"
}

# 目标证书目录里「已经有证书了吗」。
# 只看 ca.crt 与 server.crt 这两个证书本体：私钥缺失说明是残套，
# 交给 unm_check_cert 处理（它会用现有 CA 只重签 server.crt），
# 这里不去覆盖，免得把用户好不容易装过客户端的 CA 换掉。
unm_cert_dir_has_certs() {
	[ -s "$1/ca.crt" ] || [ -s "$1/server.crt" ]
}

# ---------------------------------------------------------------------------
# 把证书目录设成 $1（写 nvram），目标目录没有证书时先从默认目录拷一份过去。
#
# 为什么要在「改配置之前」拷：
#   证书目录可以指到 U 盘。U 盘路径第一次用的时候是空的，如果只改 nvram
#   不管文件，下一次 unm_check_cert 会直接在里面生成一套**全新的 CA**，
#   客户端之前装的 ca.crt 立刻失效，用户完全看不出发生了什么。
#   所以先把默认目录那套原样搬过去，客户端装的 CA 继续有效。
#
# 拷贝只在目标目录「没有任何证书」时做，目标目录已有证书一律不动。
# 目标目录不存在时只补建最后一层（理由同 unm_check_cert ②，
# 不能 mkdir -p 出一条并不存在的挂载点）。
# ---------------------------------------------------------------------------
unm_prepare_cert_dir() {
	local dir="$1"
	local src="$UNM_DEFAULT_CERT_DIR"
	local f copied n=0

	[ -n "$dir" ] || return 1
	dir=$(unm_abspath "$dir")
	while [ "$dir" != "/" ] && [ "${dir%/}" != "$dir" ]; do
		dir="${dir%/}"
	done

	if unm_cert_dir_has_certs "$dir"; then
		echo "OK|目标目录已有证书，不做拷贝：$dir"
		return 0
	fi

	# 源目录：优先出厂套装，其次是默认证书目录（$UNM_DIR）。
	# 出厂套装在 romfs 里，一定能读到；$UNM_DIR 里的那套可能是用户
	# 自己签的、或者别人已经装到客户端上的，优先级放后面。
	if ! unm_cert_dir_has_certs "$src"; then
		src="$UNM_DIR"
	fi
	if ! unm_cert_dir_has_certs "$src"; then
		echo "WARN|源目录没有可拷贝的证书：$src（目标目录会按需自动生成一套新 CA）"
		return 0
	fi

	if [ ! -d "$dir" ]; then
		if [ ! -d "$(dirname "$dir")" ]; then
			echo "ERR|[迁移证书]目标目录不存在：$dir（U 盘未挂载或路径写错），已取消"
			return 1
		fi
		if ! mkdir -p "$dir" 2>/dev/null; then
			echo "ERR|[迁移证书]无法创建目录：$dir"
			return 1
		fi
	fi
	if [ ! -w "$dir" ]; then
		echo "ERR|[迁移证书]目标目录不可写：$dir（U 盘是否只读挂载？），已取消"
		return 1
	fi

	for f in ca.crt ca.key server.crt server.key; do
		[ -f "$src/$f" ] || continue
		if cp -f "$src/$f" "$dir/$f" 2>/dev/null; then
			n=$((n + 1))
		fi
	done

	# 私钥收紧权限：cp 会沿用 umask，两个私钥不应该是 644
	chmod 600 "$dir/ca.key" "$dir/server.key" 2>/dev/null
	chmod 644 "$dir/ca.crt" "$dir/server.crt" 2>/dev/null

	if [ "$n" -eq 0 ]; then
		echo "ERR|[迁移证书]拷贝失败：$src → $dir"
		return 1
	fi

	# 拷贝后必须能验通，否则「拷了但客户端照样不认」比直接报错更难排查
	if [ -s "$dir/ca.crt" ] && [ -s "$dir/server.crt" ]; then
		if ! openssl verify -CAfile "$dir/ca.crt" "$dir/server.crt" >/dev/null 2>&1; then
			echo "WARN|已拷贝 $n 个文件到 $dir，但 server.crt 与 ca.crt 校验不通过（服务会按需重签）"
			return 0
		fi
	fi

	echo "OK|已从 $src 拷贝 $n 个证书文件到 $dir"
	if [ -s "$dir/ca.crt" ]; then
		echo "CA_END=$(openssl x509 -in "$dir/ca.crt" -noout -enddate 2>/dev/null | cut -d= -f2)"
	fi
	return 0
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
	local cfg="$UNM_CERT_DIR/dn.cnf"

	# 写不进去必须立刻报错：否则后面 openssl 只会给出
	# "Can't open ... for reading" 这种看不出根因的信息
	if ! cat >"$cfg" <<-EOF
		[req]
		distinguished_name = dn
		prompt = no
		[dn]
		[v3_ca]
		basicConstraints = critical,CA:TRUE
		keyUsage = critical,keyCertSign,cRLSign
		subjectKeyIdentifier = hash
	EOF
	then
		UNM_LAST_ERR="无法写入临时配置：$cfg（证书目录不可写？）"
		logger -t "网易云解锁" "错误：$UNM_LAST_ERR"
		rm -f "$cfg"
		return 1
	fi

	openssl genrsa -out "$UNM_CAKEY" 2048 >>/dev/null 2>&1 || return 1
	openssl req -x509 -new -nodes -key "$UNM_CAKEY" -sha256 -days 3650 \
		-config "$cfg" -reqexts v3_ca \
		-subj "/C=CN/O=UnblockNeteaseMusic/CN=UnblockNeteaseMusic Root CA" \
		-out "$UNM_CA" >>/dev/null 2>&1 || return 1
	rm -f "$cfg"
	openssl x509 -in "$UNM_CA" -noout >/dev/null 2>&1
}

unm_gen_server_cert() {
	local cfg="$UNM_CERT_DIR/ext.cnf"
	local ip san

	# SAN 里的 IP 取当前 LAN 地址：客户端直接用 IP 连 5201 时需要它，
	# 写死会让换过网段的固件在「以 IP 访问」时证书校验失败。
	# 走域名访问时起作用的是 DNS: 那几条，IP 只是兜底。
	ip=$(unm_getip)
	[ -z "$ip" ] && ip=192.168.3.1
	san="DNS:music.163.com,DNS:*.music.163.com,DNS:*.music.126.net,IP:$ip"
	[ "$ip" != "172.16.0.1" ] && san="$san,IP:172.16.0.1"

	# 写不进去要立刻报错，理由同 unm_gen_ca
	if ! cat >"$cfg" <<-EOF
		basicConstraints=CA:FALSE
		keyUsage=digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
		extendedKeyUsage=serverAuth
		subjectAltName=$san
	EOF
	then
		UNM_LAST_ERR="无法写入临时配置：$cfg（证书目录不可写？）"
		logger -t "网易云解锁" "错误：$UNM_LAST_ERR"
		rm -f "$cfg"
		return 1
	fi

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

# ---------------------------------------------------------------------------
# 证书备份/还原（只服务于 unm_check_cert ④ 分支与 regen 命令）
#   重签是破坏性的：CA 一旦被覆盖，装过旧 ca.crt 的客户端就全要重装。
#   所以动手之前先把整个证书目录里这几个文件挪成 .bak，
#   成功才删掉 .bak，失败就原样放回去。
# ---------------------------------------------------------------------------
UNM_CERT_BAK_EXT=".bak-unm"

unm_cert_backup() {
	local f

	for f in "$UNM_CA" "$UNM_CAKEY" "$UNM_CERT" "$UNM_KEY"; do
		[ -f "$f" ] || continue
		mv -f "$f" "$f$UNM_CERT_BAK_EXT" 2>/dev/null
	done
	# 旧的序列号一起挪走，保证新 CA 从干净状态开始
	[ -f "$UNM_CERT_DIR/ca.srl" ] && mv -f "$UNM_CERT_DIR/ca.srl" "$UNM_CERT_DIR/ca.srl$UNM_CERT_BAK_EXT" 2>/dev/null
	return 0
}

unm_cert_restore() {
	local f

	for f in "$UNM_CA" "$UNM_CAKEY" "$UNM_CERT" "$UNM_KEY" "$UNM_CERT_DIR/ca.srl"; do
		[ -f "$f$UNM_CERT_BAK_EXT" ] || continue
		# 新生成但不可用的半成品先删掉，不然 mv 会覆盖失败
		rm -f "$f"
		mv -f "$f$UNM_CERT_BAK_EXT" "$f" 2>/dev/null
	done
	return 0
}

unm_cert_backup_clear() {
	local f

	for f in "$UNM_CA" "$UNM_CAKEY" "$UNM_CERT" "$UNM_KEY" "$UNM_CERT_DIR/ca.srl"; do
		rm -f "$f$UNM_CERT_BAK_EXT" 2>/dev/null
	done
	return 0
}

unm_check_cert() {
	UNM_LAST_ERR=""
	unm_resolve_cert_paths

	# ---- ① 已有且可用的证书：原样复用，一个字节都不动 ----
	if unm_cert_usable; then
		if unm_cert_matches_ca && unm_key_matches_cert; then
			logger -t "网易云解锁" "证书可复用：$UNM_CERT_DIR（到期 $(openssl x509 -in "$UNM_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)）"
			return 0
		fi
		logger -t "网易云解锁" "证书与私钥/CA 不匹配，准备重新签发"
	else
		logger -t "网易云解锁" "证书缺失、损坏或 30 天内到期，准备生成"
	fi

	# ---- ② 证书目录必须存在且可写 ----
	# 只补建最后一层目录，不能 mkdir -p 出一整条路径：
	# U 盘拔掉后 /media/UDISK 不存在，而 mkdir -p 会在根文件系统上
	# 重新造出这个目录并写入一套新证书 —— 等 U 盘插回来又是另一套 CA，
	# 客户端装的 CA 就对不上了。所以父目录不存在时直接按「没挂载」处理。
	if [ ! -d "$UNM_CERT_DIR" ]; then
		if [ ! -d "$(dirname "$UNM_CERT_DIR")" ]; then
			UNM_LAST_ERR="证书目录不存在：$UNM_CERT_DIR（U 盘未挂载或路径写错）"
			logger -t "网易云解锁" "警告：$UNM_LAST_ERR"
			return 1
		fi
		mkdir -p "$UNM_CERT_DIR" 2>/dev/null
	fi
	if [ ! -w "$UNM_CERT_DIR" ]; then
		UNM_LAST_ERR="证书目录不可写：$UNM_CERT_DIR（U 盘是否只读挂载？）"
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
	# 先把现有文件挪到 .bak 再动手：重签失败时放回去，
	# 免得一次失败的尝试把客户端已经装好的 CA 彻底抹掉。
	unm_cert_backup
	logger -t "网易云解锁" "正在生成 CA（自签根证书，需安装到客户端）"
	if ! unm_gen_ca; then
		UNM_LAST_ERR="CA 生成失败（openssl 可能不支持当前 sha256）"
		logger -t "网易云解锁" "警告：$UNM_LAST_ERR"
		unm_cert_restore
		return 1
	fi

	logger -t "网易云解锁" "正在签发服务器证书"
	if unm_gen_server_cert; then
		chmod 600 "$UNM_KEY" "$UNM_CAKEY" 2>/dev/null
		unm_cert_backup_clear
		logger -t "网易云解锁" "证书就绪：$UNM_CERT"
		return 0
	fi

	UNM_LAST_ERR="证书签发失败（openssl 可能不支持当前 sha256/配置文件）"
	logger -t "网易云解锁" "警告：$UNM_LAST_ERR，将以无证书模式启动（仅 HTTP 可用）"
	unm_cert_restore
	return 1
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
		# 新版 PC 客户端用 interfacepc，不劫持它，电脑端的播放地址请求
		# 连不到本机，全部直连网易拿试听片段。
		echo "address=/interfacepc.music.163.com/$ip $UNM_DNS_MARK"
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
# 升级路径补默认值
#   shared/defaults.c 里的默认值只在「nvram 首次初始化」时写入。从旧固件
#   升级上来时 nvram 已经被初始化过，这些键根本不存在，于是出现两种后果：
#     页面：nvram_match_x(...,"1") 匹配不上 → 显示成「关」
#     脚本：unm_flag 只认精确的 "0" → 空值照旧算「开」，参数照传
#   显示和实际行为对不上。这里在启动前把空值补成默认值，
#   defaults.c 只认首次初始化，这里补的是已有键但值为空的情况。
#   只补「值为空」的，用户显式选过的 0/1 一律不动。
# ---------------------------------------------------------------------------
unm_set_default() {
	local key="$1" def="$2" cur

	cur=$(nvram get "$key")
	[ -n "$cur" ] && return 0
	nvram set "$key"="$def"
	# nvram commit 只在「确有键被补上」时做一次：
	# 它是对 /dev/nvram 的 ioctl，每次都要写 flash，没必要为六个键写六次。
	UNM_DEFAULTS_DIRTY=1
}

unm_apply_defaults() {
	UNM_DEFAULTS_DIRTY=0

	unm_set_default wyybin_bu 1
	unm_set_default wyybin_ba 1
	unm_set_default wyybin_lv 1
	unm_set_default wyybin_sef 1
	unm_set_default wyybin_wl 0
	unm_set_default wyybin_qq_enable 0

	if [ "$UNM_DEFAULTS_DIRTY" = "1" ]; then
		nvram_commit
		logger -t "网易云解锁" "已补齐缺失的功能开关默认值（升级后的首次启动）"
	fi
}

# ---------------------------------------------------------------------------
# 恢复默认配置（页面「恢复默认配置」按钮）
#
# 与 unm_apply_defaults 的区别：那个只补空值、保住用户的选择；
# 这个是**无条件**写回出厂值，用于「配置被改坏了，一键回到刚刷完固件的样子」。
#
# 默认值必须和 shared/defaults.c 的 APP_WYYBIN 段、以及页面上的
# placeholder/默认提示保持一致，改一处就要改三处：
#   wyybin_enable     0        总开关关了（用户点「恢复默认」多半是想重来，
#                              保留开启会让证书目录重置后立刻又开始跑）
#   wyybin_port       ""(5200) 留空让脚本用内置默认值，页面 placeholder 也是这个
#   wyybin_sslport    ""(5201)
#   wyybin_mode       0        纯代理
#   wyybin_source     ""(pyncmd:kuwo:kugou:migu)
#   wyybin_minscore   ""(0.75)
#   wyybin_extra      ""
#   wyybin_cert       ""(=/etc/storage/unblockneteasemusic)
#   wyybin_proxy      ""
#   wyybin_bu/ba/lv/sef  1
#   wyybin_wl          0
#   wyybin_qq_enable   0
#
# 证书目录重置回默认之后，还要确认那里真的有证书：
#   优先把出厂套装 /etc/unm-cert-default 拷回去（CA 不变，客户端不用重装）；
#   出厂套装不在（老固件）才交给 unm_check_cert 现场生成。
# ---------------------------------------------------------------------------
unm_reset_defaults() {
	local key f src="$UNM_DEFAULT_CERT_DIR" n=0

	for key in wyybin_enable wyybin_port wyybin_sslport wyybin_mode \
	           wyybin_source wyybin_minscore wyybin_extra wyybin_cert \
	           wyybin_proxy wyybin_bu wyybin_ba wyybin_lv wyybin_sef \
	           wyybin_wl wyybin_qq_enable; do
		nvram unset "$key"
	done
	nvram set wyybin_enable=0
	nvram set wyybin_mode=0
	nvram set wyybin_bu=1
	nvram set wyybin_ba=1
	nvram set wyybin_lv=1
	nvram set wyybin_sef=1
	nvram set wyybin_wl=0
	nvram set wyybin_qq_enable=0
	nvram commit
	logger -t "网易云解锁" "已恢复默认配置（页面按钮）"

	# 证书目录回到默认位置，并保证那里有一套可用证书
	unm_resolve_cert_paths

	if unm_cert_dir_has_certs "$UNM_CERT_DIR"; then
		echo "OK|证书目录已有证书，保留不动：$UNM_CERT_DIR"
	else
		if unm_cert_dir_has_certs "$src"; then
			if [ ! -d "$UNM_CERT_DIR" ]; then
				mkdir -p "$UNM_CERT_DIR" 2>/dev/null
			fi
			for f in ca.crt ca.key server.crt server.key; do
				[ -f "$src/$f" ] || continue
				cp -f "$src/$f" "$UNM_CERT_DIR/$f" 2>/dev/null && n=$((n + 1))
			done
			chmod 600 "$UNM_CERT_DIR/ca.key" "$UNM_CERT_DIR/server.key" 2>/dev/null
			chmod 644 "$UNM_CERT_DIR/ca.crt" "$UNM_CERT_DIR/server.crt" 2>/dev/null
		fi
		if [ "$n" -gt 0 ]; then
			echo "OK|已从出厂套装恢复 $n 个证书文件到 $UNM_CERT_DIR（CA 未变，客户端无需重装）"
		elif unm_check_cert; then
			echo "OK|已重新生成证书到 $UNM_CERT_DIR（CA 是新的，客户端需要重装 ca.crt）"
		else
			echo "ERR|$UNM_LAST_ERR"
		fi
	fi

	if [ -s "$UNM_CERT_DIR/ca.crt" ]; then
		echo "CA_END=$(openssl x509 -in "$UNM_CERT_DIR/ca.crt" -noout -enddate 2>/dev/null | cut -d= -f2)"
	fi

	# 配置已经回到默认，进程要按新配置重启（总开关现在是关的，所以是停）
	if [ -n "$(unm_pids)" ]; then
		unm_stop
		if [ "$(nvram get wyybin_enable)" = "1" ]; then
			unm_start >/dev/null 2>&1
		fi
	fi
	return 0
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
	local port sslport source mode extra ip args pid ms unm_forward

	if [ ! -x "$UNM_BIN" ]; then
		logger -t "网易云解锁" "错误：找不到可执行文件 $UNM_BIN"
		return 1
	fi

	# 先把升级后缺失的功能开关补成默认值，后面的读法和页面显示才对得上
	unm_apply_defaults

	# 这里不再调 unm_stop：停旧进程由调用方（start/restart 分支）负责，
	# 否则 restart 会连续停两次，每次都要等满 10 秒的优雅退出超时。
	port=$(nvram get wyybin_port)
	sslport=$(nvram get wyybin_sslport)
	source=$(nvram get wyybin_source)
	mode=$(nvram get wyybin_mode)
	args=$(nvram get wyybin_extra)

	[ -z "$port" ] && port=5200
	[ -z "$sslport" ] && sslport=5201
	# 音源默认值：pyncmd + 三家换源。
	#   排序意图不是「挨个试」，上游是**并发**搜索所有音源再按匹配分择优，
	#   顺序只影响同分时的取舍，所以这里把命中率最高的放前面。
	#   pyncmd 用网易 songId 直接换地址、不猜原唱，是最稳的一条；
	#   剩下三家补它覆盖不到的（实测约 17%），任一家挂了不影响其它家。
	# 单独一家 pyncmd 时，那个第三方 API（music-api.gdstudio.xyz）一超时
	# 整首歌就没了，这是之前「时好时坏」的直接原因，多源就是为了消掉它。
	# 老的 wyybin_source 值原样保留，所以升级固件不会改掉用户已经选好的音源。
	[ -z "$source" ] && source=pyncmd:kuwo:kugou:migu
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
	[ -z "$source" ] && source=pyncmd:kuwo:kugou:migu

	# 运行模式：0=纯代理（客户端手工指代理），1=转发模式（本脚本自己写 DNS 劫持）
	# 上游的 mode=1 会自己去改 /etc/hosts，与系统自身的记录互相覆盖，所以**永远不让
	# 上游看到 1**：进程一律以 -m 0 启动，转发模式由下面的 unm_hook_dns 用 dnsmasq
	# 规则实现。这里只把 wyybin_mode 归一化成内部用的转发开关。
	case "$mode" in
		1|2) unm_forward=1 ;;
		*) unm_forward=0 ;;
	esac
	if [ "$unm_forward" = "1" ] && [ "$mode" != "1" ]; then
		logger -t "网易云解锁" "转发模式取值范围为 0/1，忽略 wyybin_mode=$mode 并按 0（纯代理）运行"
		unm_forward=0
	fi

	# 上游参数：-a 监听地址 -p HTTP 端口 -sp HTTPS 端口 -o 音源
	#           -c/-k 证书 -m 运行模式 -l 日志文件
	#           -ms 最低匹配分（低于此分的搜索结果一律丢弃，宁缺勿错）
	#           -mtls MITM 监听地址 -mk MITM CA 私钥路径
	# -m 固定传 0：见上面的说明，上游的 hosts 劫持一律关掉，劫持由本脚本负责。
	args="-a 0.0.0.0 -p $port -sp $sslport -o $source -m 0 -l $UNM_LOG"

	# MITM：客户端把网易域名解析回本机时，CONNECT 落进 $port，隧道里是 TLS。
	# 不启用 MITM 的话这条隧道只能原样透传 —— 播放地址接口的响应不会被改写，
	# 客户端表现就是「代理连上了但 VIP 歌还是试听」，PC 端甚至像断网一样
	# （旧代码在 mips 上 tls.Dial 回环自己会报 packet length too long 直接掐断）。
	# 监听 127.0.0.1 而不是 0.0.0.0：只有本机回环能连到，不对外暴露。
	#
	# 端口必须与 $sslport 错开：-sp 自己在 0.0.0.0:$sslport 上监 TLS，
	# MITM 再绑 127.0.0.1:$sslport 会撞车（实测 "bind: address already
	# in use"，且下游 startTlsServer 的 fatal 会把整个进程带走）。
	# 用 sslport+1 作为 MITM 端口。
	mitm_port=$((sslport + 1))
	args="$args -mtls 127.0.0.1:$mitm_port -mk ${UNM_DIR:-/usr/bin}/mitm-ca.key"

	# pyncmd 的代理路由（见 config.resolveProxy）：
	#   页面留空 → 程序自己探测本机 7890/1080 等端口，探到就走代理（6s 超时），
	#              探不到就走直连（20s 超时）。实测代理下 0.5~1.1s，直连 1.2~3.3s
	#              但会偶发挂到 17.9s，所以「有代理就用」是明显更优的默认。
	#   填 none  → 强制直连
	#   填地址   → 用该地址，形如 http://127.0.0.1:7890
	proxy=$(nvram get wyybin_proxy)
	if [ -n "$proxy" ]; then
		args="$args -proxy $proxy"
	fi

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
	# 依赖客户端把 music.163.com 解析到本机，一旦劫持失效整条链路就断。
	# 现在的做法是代理进程自己接住 /unblockmusic/ 请求并直接转发音源，
	# 客户端拿到的是普通直链，链路不再有回环依赖。
	# 若确实需要旧行为，在页面「额外参数」里填 -e 即可覆盖。

	# ------------------------------------------------------------------
	# 功能开关：默认全部开启，页面上每个开关独立控制，互不影响。
	#   -bu 屏蔽升级提示   -ba 去广告   -lv 本地伪 VIP
	#   -sef 解锁音效      -wl 打印请求全文
	# 注意上游这几个是 Go 的 flag.Bool（无值开关），只能「传 = 开」、
	# 「不传 = 关」，不存在「显式传一个关」的写法。所以页面开关关掉时
	# 只是不追加这一项，不能在「额外参数」里再把它压成关。
	# ------------------------------------------------------------------
	args="$args $(unm_flag -bu wyybin_bu) $(unm_flag -ba wyybin_ba) $(unm_flag -lv wyybin_lv) $(unm_flag -sef wyybin_sef) $(unm_flag -wl wyybin_wl)"

	# 额外参数由用户在页面里填写。这里必须先筛一遍：上游 -bu/-ba/-lv/-sef/-wl
	# 全都是 Go 的 flag.Bool（无值开关），有两个坑：
	#   1) 写成 "-wl=1" 或 "-wl true" 会 flag.Parse 报错，进程直接退出；
	#   2) 重复写两次 "-wl -wl" 也会 ParseError（bool flag 已经被包装成
	#      "true" 形式，再次赋值即「多次设置」）。
	# 所以剔除本次已由开关决定的那几个，只放行其它参数（-a/-p/-sp/-o/-m/-ms/
	# -l/-c/-k/-insecure/-sl/-e/-b 以及页面没暴露但上游支持的项）。
	# 同时把它们从 args 里先摘掉，避免与下方 unm_flag 产出的重复。
	extra=$(nvram get wyybin_extra)
	if [ -n "$extra" ]; then
		extra_clean=
		for f in $extra; do
			case "$f" in
				-bu|-ba|-lv|-sef|-wl) : ;;	# 由页面开关决定，忽略
				*) extra_clean="$extra_clean $f" ;;
			esac
		done
		[ -n "$extra_clean" ] && args="$args$extra_clean"
	fi

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

	# 进程活着才装守护：这里失败（进程秒退）说明根本起不来，
	# 挂上 cron 也只会每 5 分钟重试一次崩溃，还会把日志刷爆。
	unm_cron_add

	# 转发模式：把音乐域名指向本机，客户端无需任何设置
	ip=$(unm_getip)
	if [ "$unm_forward" = "1" ]; then
		unm_hook_dns "$ip"
	fi

	return 0
}

case "$1" in
start)
	unm_stop
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
	if [ -n "$(unm_pids)" ]; then
		echo "running"
	else
		echo "stopped"
	fi
	;;
watch)
	# 守护入口，由 crontab 每 5 分钟调一次（见 unm_cron_add）。
	# 只做一件事：该在的时候不在，就拉起来。
	#
	# 为什么需要它：上游曾有一个真实的并发缺陷 —— provider.resolveSong 里
	# 多个 goroutine 同时往同一个 map 写 musicQuality，Go 抛
	# "fatal error: concurrent map read and map write" 后进程当场退出，
	# 且**不可恢复**（recover 抓不住 fatal error）。现在该写入已在
	# provider.go 的 buildSearchSong 里删掉（见 README「已知问题」），
	# 但守护仍然保留：这个 Go 二进制跑在 128MB 的 MT7621 上，
	# 内存耗尽或上游 API 行为变化同样会让进程消失，而系统 watchdog
	# 只管硬件、管不到用户态进程。
	#
	# 三道保护，缺一不可：
	#   1) 总开关关闭时立即返回，别在用户主动关服务后还反复拉起
	#   2) 5 分钟冷却：崩溃后重启需要时间，避免 cron 在启动过程中重复拉起
	#   3) 只认「进程不在」，不做端口探测 —— 探测本身要发请求，
	#      会把崩溃日志搅浑，而且进程活着但慢的时候容易被误杀重拉
	if [ "$(nvram get wyybin_enable)" != "1" ]; then
		exit 0
	fi
	if [ -n "$(unm_pids)" ]; then
		exit 0
	fi
	if [ -f "$UNM_WATCH_STAMP" ]; then
		last=$(date +%s)
		prev=$(cat "$UNM_WATCH_STAMP" 2>/dev/null)
		case "$prev" in
			''|*[!0-9]*) prev=0 ;;
		esac
		if [ $((last - prev)) -lt 300 ]; then
			exit 0
		fi
	fi
	date +%s >"$UNM_WATCH_STAMP"
	logger -t "网易云解锁" "守护检测到进程已退出，正在重新拉起"
	unm_start
	;;
cert)
	# 输出生效的证书目录与状态，页面「证书状态」用
	unm_resolve_cert_paths
	if unm_check_cert; then
		echo "OK|dir=$UNM_CERT_DIR"
		echo "END=$(openssl x509 -in "$UNM_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
		echo "SUBJ=$(openssl x509 -in "$UNM_CERT" -noout -subject 2>/dev/null | sed 's/^subject=//')"
		echo "FILES=$(ls -1 "$UNM_CERT_DIR" 2>/dev/null | tr '\n' ' ')"
	else
		echo "ERR|$UNM_LAST_ERR"
	fi
	;;
regen)
	# 强制重签：把现有证书挪到 .bak 后按同样的流程重建。
	# 这是唯一会更换 CA 的入口，页面上的按钮带二次确认。
	# 重建失败时 unm_check_cert ④ 会自己把 .bak 放回去，
	# 所以「点了重新生成但失败了」不会让服务变成没有证书的状态。
	unm_resolve_cert_paths
	rm -f "$UNM_CSR" "$UNM_EXT"
	unm_cert_backup
	logger -t "网易云解锁" "按页面请求强制重新生成证书"
	if unm_check_cert; then
		echo "OK|dir=$UNM_CERT_DIR"
		echo "END=$(openssl x509 -in "$UNM_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
		echo "SUBJ=$(openssl x509 -in "$UNM_CERT" -noout -subject 2>/dev/null | sed 's/^subject=//')"
		echo "FILES=$(ls -1 "$UNM_CERT_DIR" 2>/dev/null | tr '\n' ' ')"
	else
		echo "ERR|$UNM_LAST_ERR"
		# 目录不可写/未挂载这类失败根本走不到 unm_check_cert ④，
		# 备份还躺在目录里，这里补一次（已经是原样就什么都不做）
		unm_cert_restore
	fi
	# 证书换了之后，正在跑的进程仍捏着旧证书，需要重启
	if [ -n "$(unm_pids)" ] && [ "$(nvram get wyybin_enable)" = "1" ]; then
		unm_stop
		unm_start >/dev/null 2>&1
	fi
	;;
prepcert)
	# 页面切换「证书目录」时，**先改 nvram 之前**调用：
	#   目标目录没有证书就从默认目录拷一份过去，拷成功/无需拷贝才返回 0，
	#   页面拿到 0 才继续发 start_apply.htm 保存新路径。
	# $2 是页面输入框里的新目录（可能为空，表示回到默认目录）。
	# 失败时页面中止保存，配置里的旧路径原样保留 —— 不会出现
	# 「配置指着一个没有证书的目录」这种半残状态。
	unm_resolve_cert_paths
	dir="$2"
	[ -n "$dir" ] || dir="$UNM_DIR"
	if unm_prepare_cert_dir "$dir"; then
		echo "DIR=$(unm_abspath "$dir")"
	else
		exit 1
	fi
	;;
resetdefault)
	# 页面「恢复默认配置」：无条件写回出厂值，并把证书目录重置回默认，
	# 再按新配置重启进程（默认总开关是关的，所以实际是停掉）。
	unm_reset_defaults
	;;
*)
	echo "Usage: $0 {start|stop|restart|status|watch|cert|regen|prepcert <dir>|resetdefault}"
	exit 1
	;;
esac

exit 0
