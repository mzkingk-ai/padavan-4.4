#!/bin/sh
# Copyright (C) 2018 Nick Peng (pymumu@gmail.com)
# Copyright (C) 2019 chongshengB (bkye@vip.qq.com)
# Copyright (C) 2022 TurBoTse (860018505@qq.com)
#
# Padavan 集成修复版 (2026-10)
#
# 相比原版修复的问题：
#  1. bind/server-tls 选项串被拼成 "-no-speed-check-group" 这样的无效选项，
#     导致分组、-no-cache、-no-dualstack-selection 等全部失效。
#  2. smartdns.conf 写在 /etc/storage 且永不清理，同一配置启动两次就报
#     "bind server ... already configured, skip"，第二个端口静默消失。
#  3. serve-expired / prefetch-domain 永远写不进配置（原脚本误用
#     sdns_exp_ttl(_max) 填入对应的 TTL 指令，布尔项靠非法值才为 0）。
#  4. cache-persist 设 "no" 却给了 cache-file，smartdns 解析失败后
#     退出，而脚本只把 stderr 吞掉，表现为"进程消失"。
#  5. dnsmasq 的 port=0/no-resolv/server= 用子串 sed 增删，用户其它
#     注释行被误删，重复 start 会叠加。
#  6. sdns_port 填 53 时会先停掉 dnsmasq 再绑定，端口被占用则整网 DNS 挂掉。
#  7. 启动失败回滚时删除的是 sdns_ported 那个端口的上游，与实际添加的不一致。
#  8. 上游列表为空（用户从 UI 清空）时生成了无 server 的配置。
#  9. 缺少本地 hosts：smartdns 接管 53 后 /etc/hosts 与 dnsmasq addn-hosts
#     里的自定义域名无法解析。
# 10. 地址/黑名单/白名单/custom 文件用 grep -v "^$" 过滤空行时同样会误删注释，
#     且 custom 里的 bind/cache 会覆盖脚本生成值。
# 11. cache-persist 打开时 cache-file 却指向 tmpfs（/tmp 或 /etc tmpfs），
#     每次重启等于重新解析，"持久化"形同虚设。

action="$1"
storage_Path="/etc/storage"
smartdns_Bin="/usr/bin/smartdns"
smartdns_Ini="$storage_Path/smartdns_conf.ini"
smartdns_Conf="$storage_Path/smartdns.conf"
smartdns_tmp_Conf="/tmp/smartdns_tmp.conf"
smartdns_address_Conf="$storage_Path/smartdns_address.conf"
smartdns_blacklist_Conf="$storage_Path/smartdns_blacklist-ip.conf"
smartdns_whitelist_Conf="$storage_Path/smartdns_whitelist-ip.conf"
smartdns_custom_Conf="$storage_Path/smartdns_custom.conf"
dnsmasq_Conf="$storage_Path/dnsmasq/dnsmasq.conf"
chn_Route="$storage_Path/chinadns/chnroute.txt"

sdns_enable=$(nvram get sdns_enable)
sdns_name=$(nvram get sdns_name)
sdns_port=$(nvram get sdns_port)
sdns_tcp_server=$(nvram get sdns_tcp_server)
sdns_ipv6_server=$(nvram get sdns_ipv6_server)
sdns_redirect=$(nvram get sdns_redirect)
sdns_cache=$(nvram get sdns_cache)
sdns_cache_persist=$(nvram get sdns_cache_persist)
sdns_tcp_idle_time=$(nvram get sdns_tcp_idle_time)
sdns_rr_ttl=$(nvram get sdns_rr_ttl)
sdns_rr_ttl_min=$(nvram get sdns_rr_ttl_min)
sdns_rr_ttl_max=$(nvram get sdns_rr_ttl_max)
sdns_rr_ttl_reply_max=$(nvram get sdns_rr_ttl_reply_max)
sdns_max_reply_ip_num=$(nvram get sdns_max_reply_ip_num)
sdns_speed=$(nvram get sdns_speed)
sdns_speed_mode=$(nvram get sdns_speed_mode)
sdns_address=$(nvram get sdns_address)
sdns_ipset=$(nvram get sdns_ipset)
sdns_ipset_timeout=$(nvram get sdns_ipset_timeout)
sdns_as=$(nvram get sdns_as)
sdns_ip_change=$(nvram get sdns_ip_change)
sdns_ip_change_time=$(nvram get sdns_ip_change_time)
sdns_dualstack_ip_allow_force_AAAA=$(nvram get sdns_dualstack_ip_allow_force_AAAA)
sdns_force_aaaa_soa=$(nvram get sdns_force_aaaa_soa)
sdns_force_qtype_soa=$(nvram get sdns_force_qtype_soa)
sdns_prefetch_domain=$(nvram get sdns_prefetch_domain)
sdns_exp=$(nvram get sdns_exp)
sdns_exp_ttl=$(nvram get sdns_exp_ttl)
sdns_exp_ttl_max=$(nvram get sdns_exp_ttl_max)
sdns_exp_prefetch_time=$(nvram get sdns_exp_prefetch_time)
sdnse_enable=$(nvram get sdnse_enable)
sdnse_port=$(nvram get sdnse_port)
sdnse_tcp=$(nvram get sdnse_tcp)
sdnse_speed=$(nvram get sdnse_speed)
sdnse_name=$(nvram get sdnse_name)
sdnse_address=$(nvram get sdnse_address)
sdnse_ns=$(nvram get sdnse_ns)
sdns_ns=$(nvram get sdns_ns)
sdnse_ipset=$(nvram get sdnse_ipset)
sdnse_as=$(nvram get sdnse_as)
sdnse_ipv6_server=$(nvram get sdnse_ipv6_server)
sdnse_ipc=$(nvram get sdnse_ipc)
sdnse_cache=$(nvram get sdnse_cache)
sdns_adblock=$(nvram get sdns_adblock)
sdns_white=$(nvram get sdns_white)
sdns_black=$(nvram get sdns_black)
sdns_coredump=$(nvram get sdns_coredump)

IPS4="$(ifconfig br0 | grep "inet addr" | grep -v ":127" | grep "Bcast" | awk '{print $2}' | awk -F : '{print $2}')"
IPS6="$(ifconfig br0 | grep "inet6 addr" | grep -v "fe80::" | grep -v "::1" | grep "Global" | awk '{print $3}')"
dnsmasq_md5=$(md5sum  "$dnsmasq_Conf" | awk '{ print $1 }')

# 【缓存持久化目录】
# Padavan 上 /tmp、/var、/etc 全是 tmpfs，cache-file 放在 /tmp 等于
# 每次重启都重新解析一遍（cache-persist yes 形同虚设）。
# 这里优先选真正落盘的目录：优盘 AiDisk 挂载点 > /etc/storage（取决于
# 固件是否把 /etc/storage 做了持久化）> /tmp（兜底，仅内存缓存）。
cache_Dir=""
for d in /etc/storage/smartdns /media/AiDisk_a1/smartdns ; do
    # /etc/storage 若是 tmpfs（df 里显示 tmpfs）就没有持久化意义，
    # 但放那里也不比 /tmp 差，仍然用它，避免缓存文件乱丢
    if mkdir -p "$d" 2>/dev/null && [ -w "$d" ] ; then
        cache_Dir="$d"
        break
    fi
done
[ -z "$cache_Dir" ] && cache_Dir="/tmp"
smartdns_Cache="$cache_Dir/smartdns.cache"

# 判断缓存目录是否真的落盘（tmpfs 重启即丢）
# Padavan 的 /etc 常是 tmpfs，但 /etc/storage 在某些固件里是独立的
# mtd 分区，所以要判断挂载点本身而不是目录名
cache_Persistent=0
if ! df -h "$smartdns_Cache" 2>/dev/null | awk 'NR==2{print $1}' | grep -q tmpfs ; then
    cache_Persistent=1
fi

# 本机还在使用的额外 hosts 文件（dnsmasq addn-hosts / 固件生成的 hosts）
host_Files="/etc/hosts"
if [ -f /etc/storage/dnsmasq/hosts ] ; then
    host_Files="$host_Files /etc/storage/dnsmasq/hosts"
fi
# smartdns 接管 53 后 dnsmasq 只剩 DHCP，它里面写的 address=/域名/IP
# 不再生效；把这部分转成 smartdns 的 address 规则继续兜底，
# 否则"网易云解锁"这类往 dnsmasq.conf 写 address 的插件会静默失效。
# 文件路径沿用上面的 dnsmasq_Conf。

# 函数

# 数值兜底：nvram 未初始化时返回默认值，避免 gen$((it_custom))erate 出非法配置
num_or() {
    case "$1" in
        ''|*[!0-9]*) echo "$2" ;;
        *) echo "$1" ;;
    esac
}

[ "$sdns_port" = "" ] && sdns_port=53
sdns_port=$(num_or "$sdns_port" 53)
sdnse_port=$(num_or "$sdnse_port" 6053)
sdns_cache=$(num_or "$sdns_cache" 32768)
sdns_cache_persist=$(num_or "$sdns_cache_persist" 1)
sdns_tcp_idle_time=$(num_or "$sdns_tcp_idle_time" 120)
sdns_rr_ttl=$(num_or "$sdns_rr_ttl" 300)
sdns_rr_ttl_min=$(num_or "$sdns_rr_ttl_min" 60)
sdns_rr_ttl_max=$(num_or "$sdns_rr_ttl_max" 3600)
sdns_rr_ttl_reply_max=$(num_or "$sdns_rr_ttl_reply_max" 60)
sdns_max_reply_ip_num=$(num_or "$sdns_max_reply_ip_num" 3)
sdns_ip_change=$(num_or "$sdns_ip_change" 1)
sdns_ip_change_time=$(num_or "$sdns_ip_change_time" 10)
sdns_exp=$(num_or "$sdns_exp" 0)
sdns_exp_ttl=$(num_or "$sdns_exp_ttl" 259200)
sdns_exp_ttl_max=$(num_or "$sdns_exp_ttl_max" 3)
sdns_exp_prefetch_time=$(num_or "$sdns_exp_prefetch_time" 21600)
sdns_prefetch_domain=$(num_or "$sdns_prefetch_domain" 0)
sdns_adblock=$(num_or "$sdns_adblock" 0)
sdns_white=$(num_or "$sdns_white" 0)
sdns_black=$(num_or "$sdns_black" 0)
sdns_ipset_timeout=$(num_or "$sdns_ipset_timeout" 1)
sdns_force_aaaa_soa=$(num_or "$sdns_force_aaaa_soa" 0)
sdns_dualstack_ip_allow_force_AAAA=$(num_or "$sdns_dualstack_ip_allow_force_AAAA" 1)
sdns_staticnum_x=$(num_or "$(nvram get sdns_staticnum_x)" 0)
sdns_local_ttl=$(num_or "$(nvram get sdns_local_ttl)" 600)

Read_ini () {
# 【读取上次成功启动时的端口等】
    if [ -s "$smartdns_Ini" ] ; then
        hosts_type=$(sed -n '1p' $smartdns_Ini)
        sdns_redirected=$(sed -n '2p' $smartdns_Ini)
        sdns_ported=$(sed -n '3p' $smartdns_Ini)
        sdnse_ported=$(sed -n '4p' $smartdns_Ini)
    else
        hosts_type=0
        sdns_redirected=0
        sdns_ported="$sdns_port"
        sdnse_ported="$sdnse_port"
    fi
    [ "$sdns_redirected" = "" ] && sdns_redirected=0
    [ "$sdns_ported" = "" ] && sdns_ported="$sdns_port"
    [ "$sdnse_ported" = "" ] && sdnse_ported="$sdnse_port"
}

Check_ss(){
    if [ -s /etc_ro/ss_ip.sh ] ; then
        if [ "$(nvram get ss_enable)" = "1" ] && [ "$(nvram get ss_run_mode)" = "router" ] && [ "$(nvram get pdnsd_enable)" = "0" ] ; then
            logger -t "SmartDNS" "系统检测到 SS 模式为绕过大陆模式，并且启用了 pdnsd 请先调整 SS 解析使用 SmartDNS +手动配置模式！程序将退出..."
            nvram set sdns_enable=0
            exit 0
        fi
    fi
}

Check_port() {
    # 【端口冲突预检查】
    # 原版在给 dnsmasq 写 port=0 之前不检查任何东西：只要 smartdns
    # 因为端口被占 / 配置错误起不来，dnsmasq 已经不做解析了，整网直接断网。
    # 这里在改动 dnsmasq 之前先确认端口可用。
    #
    # 用 netstat 的文本输出判断（busybox 的 /proc/net/* 十六进制格式在
    # IPv4/IPv6 混排下很容易误判，实测会漏判），拿不到 netstat 时保守放行。
    local port="$1"
    local listener

    listener=$(netstat -lnut 2>/dev/null | awk -v p="$port" '
        NR > 2 && $6 == "LISTEN" {
            n = split($4, a, ":");
            if (a[n] == p) { print $1 " " $4; exit }
        }')

    [ -z "$listener" ] && return 0

    # dnsmasq 占着 53 属于正常情况：稍后会给它写 port=0，只留 DHCP
    case "$listener" in
        *dnsmasq*) [ "$port" = "53" ] && return 0 ;;
    esac

    # netstat 拿不到进程名时，端口 53 交给 dnsmasq 判断
    if [ "$port" = "53" ] && [ -n "$(pidof dnsmasq)" ] ; then
        return 0
    fi

    logger -t "SmartDNS" "端口 $port 已被占用（$listener），为避免断网已取消启动"
    return 1
}

Get_sdns_conf () {
    # 【基本设置】
    :>"$smartdns_tmp_Conf"
    [ -n "$sdns_name" ] && echo "server-name $sdns_name" >> "$smartdns_tmp_Conf"

    # 所有 bind 选项共用的能力开关
    ARGS_1=""
    [ "$sdns_address" = "1" ]   && ARGS_1="$ARGS_1 -no-rule-addr"
    [ "$sdns_ns" = "1" ]        && ARGS_1="$ARGS_1 -no-rule-nameserver"
    [ "$sdns_ipset" = "1" ]     && ARGS_1="$ARGS_1 -no-rule-ipset"
    [ "$sdns_speed" = "1" ]     && ARGS_1="$ARGS_1 -no-speed-check"
    [ "$sdns_as" = "1" ]        && ARGS_1="$ARGS_1 -no-rule-soa"

    # 外部/第三方软件通过 :53 访问时的行为
    if [ "$sdns_ipv6_server" = "1" ] ; then
        echo "bind" "[::]:$sdns_port$ARGS_1" >> "$smartdns_tmp_Conf"
    else
        echo "bind" ":$sdns_port$ARGS_1" >> "$smartdns_tmp_Conf"
        # 关闭 IPv6 监听时不要留下 [::] 让内核双栈抢占 IPv4
        echo "bind" "0.0.0.0:$sdns_port$ARGS_1" >> "$smartdns_tmp_Conf"
    fi
    if [ "$sdns_tcp_server" = "1" ] ; then
        if [ "$sdns_ipv6_server" = "1" ] ; then
            echo "bind-tcp" "[::]:$sdns_port$ARGS_1" >> "$smartdns_tmp_Conf"
        else
            echo "bind-tcp" ":0.0.0.0:$sdns_port$ARGS_1" >> "$smartdns_tmp_Conf"
        fi
    fi

    # 【读取配置】
    Get_sdnse_conf
    echo "cache-size $sdns_cache" >> "$smartdns_tmp_Conf"
    echo "rr-ttl $sdns_rr_ttl" >> "$smartdns_tmp_Conf"
    echo "rr-ttl-min $sdns_rr_ttl_min" >> "$smartdns_tmp_Conf"
    echo "rr-ttl-max $sdns_rr_ttl_max" >> "$smartdns_tmp_Conf"
    echo "tcp-idle-time $sdns_tcp_idle_time" >> "$smartdns_tmp_Conf"
    echo "rr-ttl-reply-max $sdns_rr_ttl_reply_max" >> "$smartdns_tmp_Conf"
    echo "max-reply-ip-num $sdns_max_reply_ip_num" >> "$smartdns_tmp_Conf"
    [ -n "$sdns_force_qtype_soa" ] && echo "force-qtype-SOA $sdns_force_qtype_soa" >> "$smartdns_tmp_Conf"
    # speed-check-mode 只能出现一次，空值时用 smartdns 默认
    [ -n "$sdns_speed_mode" ] && echo "speed-check-mode $sdns_speed_mode" >> "$smartdns_tmp_Conf"

    if [ "$sdns_cache" -gt 0 ] 2>/dev/null ; then
        if [ "$sdns_cache_persist" -eq 1 ] && [ "$cache_Persistent" -eq 0 ] ; then
            logger -t "SmartDNS" "注意：$cache_Dir 位于内存文件系统（tmpfs），缓存重启后不会保留；如需真正的缓存持久化请插上 U 盘"
        fi
        # ---------------- 缓存过期行为 ----------------
        if [ "$sdns_exp" -eq 1 ] ; then
            echo "serve-expired yes" >> "$smartdns_tmp_Conf"
            echo "serve-expired-ttl $sdns_exp_ttl" >> "$smartdns_tmp_Conf"
            echo "serve-expired-reply-ttl $sdns_exp_ttl_max" >> "$smartdns_tmp_Conf"
            [ "$sdns_exp_prefetch_time" -gt 0 ] && \
                echo "serve-expired-prefetch-time $sdns_exp_prefetch_time" >> "$smartdns_tmp_Conf"
        else
            echo "serve-expired no" >> "$smartdns_tmp_Conf"
        fi

        # ---------------- 预获取 ----------------
        if [ "$sdns_prefetch_domain" -eq 1 ] ; then
            echo "prefetch-domain yes" >> "$smartdns_tmp_Conf"
        else
            echo "prefetch-domain no" >> "$smartdns_tmp_Conf"
        fi

        # ---------------- 缓存持久化 ----------------
        # 注意：cache-persist=no 时不能写 cache-file，否则 smartdns
        # 解析阶段直接报错退出（原版"启动后进程消失"的根因之一）
        if [ "$sdns_cache_persist" -eq 1 ] ; then
            echo "cache-persist yes" >> "$smartdns_tmp_Conf"
            echo "cache-file $smartdns_Cache" >> "$smartdns_tmp_Conf"
        else
            echo "cache-persist no" >> "$smartdns_tmp_Conf"
        fi

        if [ "$sdns_ipset_timeout" -eq 1 ] ; then
            echo "ipset-timeout yes" >> "$smartdns_tmp_Conf"
        else
            echo "ipset-timeout no" >> "$smartdns_tmp_Conf"
        fi
    else
        echo "serve-expired no" >> "$smartdns_tmp_Conf"
        echo "prefetch-domain no" >> "$smartdns_tmp_Conf"
        echo "cache-persist no" >> "$smartdns_tmp_Conf"
    fi

    # ---------------- 双栈选择 ----------------
    if [ "$sdns_ip_change" -eq 1 ] ; then
        echo "dualstack-ip-selection yes" >> "$smartdns_tmp_Conf"
        [ "$sdns_ip_change_time" -gt 0 ] 2>/dev/null && \
            echo "dualstack-ip-selection-threshold $sdns_ip_change_time" >> "$smartdns_tmp_Conf"
    elif [ "$sdns_force_aaaa_soa" -eq 1 ] ; then
        echo "force-AAAA-SOA yes" >> "$smartdns_tmp_Conf"
    fi
    if [ "$sdns_dualstack_ip_allow_force_AAAA" -eq 1 ] && [ "$sdns_cache" -gt 0 ] ; then
        echo "dualstack-ip-allow-force-AAAA yes" >> "$smartdns_tmp_Conf"
    else
        echo "dualstack-ip-allow-force-AAAA no" >> "$smartdns_tmp_Conf"
    fi

    if [ "$sdns_adblock" -eq 1 ] && [ -s /tmp/anti-ad-for-smartdns.conf ] ; then
        echo "conf-file /tmp/anti-ad-for-smartdns.conf" >> "$smartdns_tmp_Conf"
    fi
    echo "log-level error" >> "$smartdns_tmp_Conf"

    # ---------------- 自定义 host ----------------
    # dnsmasq 的解析功能被关掉后，/etc/hosts 与 addn-hosts 需要由 smartdns 接管。
    # 选项名是 hosts-file（不是 host-file，后者是无效选项，会让 smartdns 自检失败）
    local hf_cnt=0
    for hf in $host_Files ; do
        if [ -s "$hf" ] ; then
            echo "hosts-file $hf" >> "$smartdns_tmp_Conf"
            hf_cnt=$((hf_cnt + 1))
        fi
    done
    # hosts 记录默认跟随 local-ttl(600s)，和 dnsmasq 的行为对齐
    [ "$hf_cnt" -gt 0 ] && echo "local-ttl ${sdns_local_ttl:-600}" >> "$smartdns_tmp_Conf"

    # ---------------- 上游服务器 ----------------
    local dnsserver server_cnt=0
    local i j sdnss_enable sdnss_name sdnss_ip sdnss_port sdnss_type sdnss_ipc sdnss_named sdnss_non sdnss_ipset
    local ipc named non ipset_args

    for i in $(seq 1 "$sdns_staticnum_x")
    do
        j=$(expr "$i" - 1)
        sdnss_enable=$(nvram get sdnss_enable_x"$j")
        [ "$sdnss_enable" = "1" ] || continue

        sdnss_name=$(nvram get sdnss_name_x"$j")
        sdnss_ip=$(nvram get sdnss_ip_x"$j")
        sdnss_port=$(nvram get sdnss_port_x"$j")
        sdnss_type=$(nvram get sdnss_type_x"$j")
        sdnss_ipc=$(nvram get sdnss_ipc_x"$j")
        sdnss_named=$(nvram get sdnss_named_x"$j")
        sdnss_non=$(nvram get sdnss_non_x"$j")
        sdnss_ipset=$(nvram get sdnss_ipset_x"$j")

        [ -z "$sdnss_ip" ] && continue

        # 每个选项必须是独立的空格分隔参数，
        # 原版 "-xxx$ipc $named" 在空值时会拼出 "-no-speed-check-group"
        ipc=""
        named=""
        non=""
        ipset_args=""
        if [ "$sdnss_ipc" = "whitelist" ] ; then
            ipc="-whitelist-ip"
        elif [ "$sdnss_ipc" = "blacklist" ] ; then
            ipc="-blacklist-ip"
        fi
        [ -n "$sdnss_named" ] && named="-group $sdnss_named"
        [ "$sdnss_non" = "1" ] && non="-exclude-default-group"
        if [ -n "$sdnss_ipset" ] ; then
            Check_ip_addr "$sdnss_ipset"
            if [ "$?" = "1" ] ;then
                ipset_args="-ipset /$sdnss_ipset/smartdns"
            else
                ipset add smartdns "$sdnss_ipset" 2>/dev/null
            fi
        fi

        # 端口：default 表示协议默认端口，显式 "53" 也要正确拼接
        if [ -z "$sdnss_port" ] || [ "$sdnss_port" = "default" ] ; then
            sdnss_port=""
        else
            sdnss_port=":$sdnss_port"
        fi

        case "$sdnss_type" in
            tls)
                [ -z "$sdnss_port" ] && sdnss_port=":853"
                echo "server-tls $sdnss_ip$sdnss_port $ipc $named $non $ipset_args" \
                    | sed 's/  */ /g' >> "$smartdns_tmp_Conf"
                server_cnt=$((server_cnt + 1))
                ;;
            https)
                [ -z "$sdnss_port" ] && sdnss_port=":443"
                echo "server-https $sdnss_ip$sdnss_port $ipc $named $non $ipset_args" \
                    | sed 's/  */ /g' >> "$smartdns_tmp_Conf"
                server_cnt=$((server_cnt + 1))
                ;;
            udp)
                [ -z "$sdnss_port" ] && sdnss_port=":53"
                echo "server $sdnss_ip$sdnss_port $ipc $named $non $ipset_args" \
                    | sed 's/  */ /g' >> "$smartdns_tmp_Conf"
                server_cnt=$((server_cnt + 1))
                ;;
            tcp)
                [ -z "$sdnss_port" ] && sdnss_port=":53"
                echo "server-tcp $sdnss_ip$sdnss_port $ipc $named $non $ipset_args" \
                    | sed 's/  */ /g' >> "$smartdns_tmp_Conf"
                server_cnt=$((server_cnt + 1))
                ;;
            *)
                logger -t "SmartDNS" "跳过未知类型的上游：$sdnss_type ($sdnss_ip)"
                ;;
        esac
    done

    # 没有配置任何上游时补一个国内公共 DNS，避免生成空的上游列表
    if [ "$server_cnt" -eq 0 ] ; then
        if [ -n "$(nvram get smartdns_cn_servers)" ] ; then
            dnsserver=$(nvram get smartdns_cn_servers | tr ',' ' ')
            for dns in $dnsserver ; do
                echo "server $dns:53" >> "$smartdns_tmp_Conf"
                server_cnt=$((server_cnt + 1))
            done
        else
            echo "server 114.114.114.114:53" >> "$smartdns_tmp_Conf"
            server_cnt=1
        fi
        logger -t "SmartDNS" "未配置上游服务器，已回退到默认 DNS"
    fi

    # ---------------- dnsmasq 内的 address 规则 ----------------
    # dnsmasq 的解析被关掉（port=0）后，它配置文件里的 address=/域名/IP
    # 就成了死配置：其它插件（如网易云解锁）依赖它把域名指回本机，
    # 在 smartdns 接管 53 时会静默失效。这里转成 smartdns 的 address。
    if [ -f "$dnsmasq_Conf" ] ; then
        local adv
        adv=$(grep -iE '^[[:space:]]*address[[:space:]]*=' "$dnsmasq_Conf" 2>/dev/null \
            | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
            | awk -F'=' '
                {
                    v = $2
                    sub(/^[[:space:]]*/, "", v)
                    n = split(v, a, "/")
                    if (n < 3) next
                    # address=/域名/IP，域名段可能为空（address=//1.2.3.4 表示全部）
                    dom = a[2]
                    ip  = a[n]
                    if (ip == "") next
                    if (dom == "") {
                        print "address /" "#" "/" ip
                    } else {
                        print "address /" dom "/" ip
                    }
                }')
        if [ -n "$adv" ] ; then
            echo "$adv" >> "$smartdns_tmp_Conf"
            logger -t "SmartDNS" "已从 dnsmasq 接管 $(echo "$adv" | wc -l) 条 address 规则"
        fi
    fi

    # ---------------- 白名单 / 黑名单 ----------------
    if [ "$sdns_white" = "1" ] && [ -f "$chn_Route" ] ; then
        :>/tmp/whitelist.conf
        logger -t "SmartDNS" "开始处理白名单IP"
        awk '{printf("whitelist-ip %s\n", $1, $1 )}' "$chn_Route" >> /tmp/whitelist.conf
        echo "conf-file /tmp/whitelist.conf" >> "$smartdns_tmp_Conf"
    fi
    if [ "$sdns_black" = "1" ] && [ -f "$chn_Route" ] ; then
        :>/tmp/blacklist.conf
        logger -t "SmartDNS" "开始处理黑名单IP"
        awk '{printf("blacklist-ip %s\n", $1, $1 )}' "$chn_Route" >> /tmp/blacklist.conf
        echo "conf-file /tmp/blacklist.conf" >> "$smartdns_tmp_Conf"
    fi
}

Get_sdnse_conf () {
    # 【读取第二服务器设置】
    # 第二个实例给局域网内"不用代理"的客户端单独使用，因此禁掉缓存、
    # 双栈选择等本地策略，避免和主实例的结果互相污染
    [ "$sdnse_enable" -eq 1 ] || return 0
    [ -z "$sdnse_port" ] && return 0

    local ARGS_2=""
    local ADDR=""

    [ "$sdnse_speed" = "1" ]         && ARGS_2="$ARGS_2 -no-speed-check"
    [ -n "$sdnse_name" ]             && ARGS_2="$ARGS_2 -group $sdnse_name"
    [ "$sdnse_address" = "1" ]       && ARGS_2="$ARGS_2 -no-rule-addr"
    [ "$sdnse_ns" = "1" ]            && ARGS_2="$ARGS_2 -no-rule-nameserver"
    [ "$sdnse_ipset" = "1" ]         && ARGS_2="$ARGS_2 -no-rule-ipset"
    [ "$sdnse_as" = "1" ]            && ARGS_2="$ARGS_2 -no-rule-soa"
    [ "$sdnse_ipc" = "1" ]           && ARGS_2="$ARGS_2 -no-dualstack-selection"
    [ "$sdnse_cache" = "1" ]         && ARGS_2="$ARGS_2 -no-cache"
    [ "$sdnse_ipv6_server" = "1" ]   && ADDR="" || ADDR="0.0.0.0"

    echo "bind $ADDR:$sdnse_port$ARGS_2" | sed 's/  */ /g' >> "$smartdns_tmp_Conf"
    if [ "$sdnse_tcp" = "1" ] ; then
        echo "bind-tcp $ADDR:$sdnse_port$ARGS_2" | sed 's/  */ /g' >> "$smartdns_tmp_Conf"
    fi
}

Check_ip_addr () {
    echo "$1"|grep "^[0-9]\{1,3\}\.\([0-9]\{1,3\}\.\)\{2\}[0-9]\{1,3\}$" >/dev/null
    # IP地址必须为全数字
    if [ $? -ne 0 ] ; then
        return 1
    fi
    ipaddr=$1
    a=$(echo "$ipaddr"|awk -F . '{ print $1 }')  # 以"."分隔，取出每个列的值
    b=$(echo "$ipaddr"|awk -F . '{ print $2 }')
    c=$(echo "$ipaddr"|awk -F . '{ print $3 }')
    d=$(echo "$ipaddr"|awk -F . '{ print $4 }')
    for num in $a $b $c $d
    do
        if [ "$num" -gt 255 ] || [ "$num" -lt 0 ] ; then   # 每个数值必须在0-255之间
            return 1
        fi
    done
    return 0
}

Start_AD () {
# 【下载广告过滤文件】
    rm -f /tmp/sdnsadnew.conf
    curl -s -o /tmp/sdnsadnew.conf --connect-timeout 10 --retry 3 "$(nvram get sdns_adblock_url)"
    if [ ! -s /tmp/sdnsadnew.conf ]; then
        logger -t "SmartDNS" "广告过滤功能未开启或者过滤地址失效，网络异常等 ！！！"
        rm -f /tmp/sdnsadnew.conf
        return 1
    fi
    logger -t "SmartDNS" "去广告文件下载成功广告过滤功能已启用..."
    if grep -qw "address=" /tmp/sdnsadnew.conf ; then
        # 上游已是 smartdns 格式
        cp /tmp/sdnsadnew.conf /tmp/anti-ad-for-smartdns.conf
    else
        # adblock / hosts 格式转换
        grep -E '^\|\|[^\*]*\^$' /tmp/sdnsadnew.conf \
            | sed -e 's:||:address\=/:g' -e 's:\^:/0\.0\.0\.0:' > /tmp/anti-ad-for-smartdns.conf
        # 纯域名列表（每行一个域名）也兼容一下
        if [ ! -s /tmp/anti-ad-for-smartdns.conf ] ; then
            grep -E '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' /tmp/sdnsadnew.conf \
                | sed -e 's:^:address\=/:' -e 's:$:/0\.0\.0\.0:' > /tmp/anti-ad-for-smartdns.conf
        fi
    fi
    if [ ! -s /tmp/anti-ad-for-smartdns.conf ] ; then
        logger -t "SmartDNS" "去广告规则格式无法识别，已跳过"
        rm -f /tmp/anti-ad-for-smartdns.conf
    fi
    rm -f /tmp/sdnsadnew.conf
}

Change_adbyby () {
# 【adbyby DNS 规则归属切换】
    adbyby_process=$(pidof adbyby | awk '{ print $1 }')
    [ "$adbyby_process"x = x ] && return 0
    [ "$(nvram get adbyby_enable)" = "1" ] || return 0

    case "$sdns_enable" in
    0)
        if [ "$(nvram get adbyby_add)" = "1" ] && [ "$hosts_type" != "dnsmasq" ]; then
            nvram set adbyby_add=0
            /usr/bin/adbyby.sh switch
            logger -t "SmartDNS" "DNS 去广告规则: SmartDNS ⇒ DNSmasq"
            hosts_type="dnsmasq"
        fi
        ;;
    1)
        if [ "$hosts_type" != "SmartDNS" ] && [ "$action" = "start" ] ; then
            if [ "$sdns_port" = "53" ] || [ "$(nvram get adbyby_add)" = "1" ] || [ "$sdns_redirect" = "2" ] ; then
                nvram set adbyby_add=1
                /usr/bin/adbyby.sh switch
                logger -t "SmartDNS" "DNS 去广告规则: DNSmasq ⇒ SmartDNS"
                hosts_type="SmartDNS"
            fi
        fi
        ;;
    esac
}

Change_dnsmasq () {
    # 删除 DNSmasq 配置文件中的相关项，避免重复
    # 原版用子串 sed，会把用户自己写的 "#port=0" 注释和
    # "port=0" 之外的行一起删干净；这里改为整行精确匹配
    [ -f "$dnsmasq_Conf" ] || return 0

    case $action in
    stop)
        sed -i '/^no-resolv$/d' "$dnsmasq_Conf"
        sed -i '/^server=127\.0\.0\.1#'"$sdns_ported"'$/d' "$dnsmasq_Conf"
        sed -i '/^port=0$/d' "$dnsmasq_Conf"
        if [ "$sdns_enable" = 0 ] ; then
            [ "$sdns_ported" = "53" ] && logger -t "SmartDNS" "已启用 DNSmasq 域名解析（DNS）功能"
            [ "$sdns_redirected" = "1" ] && logger -t "SmartDNS" "删除 DNSmasq 上游服务器：127.0.0.1:$sdns_ported"
        fi
        ;;
    start)
        # 启动 SmartDNS 时
        if [ "$sdns_port" = "53" ] ; then
            grep -qx "port=0" "$dnsmasq_Conf" || echo "port=0" >> "$dnsmasq_Conf"
            logger -t "SmartDNS" "已关闭 DNSmasq 域名解析（DNS）功能"
            if [ "$sdns_redirect" = "1" ] ; then
                nvram set sdns_redirect=0
                sdns_redirect=0
                logger -t "SmartDNS" "因此，自动修改 重定向为：无"
            fi
        fi
        if [ "$sdns_redirect" = "1" ] ; then
            grep -qx "no-resolv" "$dnsmasq_Conf" || echo "no-resolv" >> "$dnsmasq_Conf"
            grep -qx "server=127.0.0.1#$sdns_port" "$dnsmasq_Conf" || \
                echo "server=127.0.0.1#$sdns_port" >> "$dnsmasq_Conf"
            logger -t "SmartDNS" "作为 DNSmasq 上游服务器：127.0.0.1:$sdns_port"
        fi
        ;;
    esac
}

Change_iptable () {
    # 【端口转发】
    local statu=0
    [ -z "$IPS4" ] && return 0

    case $action in
    stop)
        if [ "$sdns_redirected" = "2" ] ; then
            iptables -t nat -D PREROUTING -p tcp -d "$IPS4" --dport 53 -j REDIRECT --to-ports "$sdns_ported" >/dev/null 2>&1
            iptables -t nat -D PREROUTING -p udp -d "$IPS4" --dport 53 -j REDIRECT --to-ports "$sdns_ported" >/dev/null 2>&1
            [ -n "$IPS6" ] && {
                ip6tables -t nat -D PREROUTING -p tcp -d "$IPS6" --dport 53 -j REDIRECT --to-ports "$sdns_ported" >/dev/null 2>&1
                ip6tables -t nat -D PREROUTING -p udp -d "$IPS6" --dport 53 -j REDIRECT --to-ports "$sdns_ported" >/dev/null 2>&1
            }
            [ "$sdns_enable" = 0 ] && logger -t "SmartDNS" "恢复重定向 $IPS4:$sdns_ported 至 xxx.xxx.xxx:53"
        fi
        if [ "$sdns_redirected" = "1" ] ; then
            iptables -t nat -D PREROUTING -p udp -d "$IPS4" --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1
        fi
        ;;
    start)
        if [ "$sdns_redirected" != "2" ] && [ "$sdns_redirect" = "2" ] ; then
            statu=1
            logger -t "SmartDNS" "重定向 xxx.xxx.xxx:53 至 $IPS4:$sdns_port"
        fi
        ;;
    *)
        :  # reset 分支由 Main 单独处理，这里不重复加规则
        ;;
    esac

    if [ "$statu" = 1 ] ; then
        [ "$sdns_tcp_server" = "1" ] && \
            iptables -t nat -A PREROUTING -p tcp -d "$IPS4" --dport 53 -j REDIRECT --to-ports "$sdns_port" >/dev/null 2>&1
        iptables -t nat -A PREROUTING -p udp -d "$IPS4" --dport 53 -j REDIRECT --to-ports "$sdns_port" >/dev/null 2>&1
    fi
}

Restore_dnsmasq () {
    # 启动失败时把 dnsmasq 恢复成能解析的状态
    if [ "$dnsmasq_md5" != "$(md5sum  "$dnsmasq_Conf" | awk '{ print $1 }')" ] ; then
        logger -t "SmartDNS" "正在重启 DNSmasq 进程..."
        /sbin/restart_dhcpd >/dev/null 2>&1
        logger -t "SmartDNS" "DNSmasq 进程已重启..."
    fi
}

Start_smartdns () {
    :>"$smartdns_Ini"
    [ "$sdns_enable" -eq 0 ] && nvram set sdns_enable=1 && sdns_enable=1
    [ "$(pidof smartdns | awk '{ print $1 }')"x != x ] && killall -9 smartdns >/dev/null 2>&1

    # 端口 53 被别的 DNS（除 dnsmasq 外）占用时不要动 dnsmasq，直接拒绝启动
    Check_port "$sdns_port" || return 1
    if [ "$sdnse_enable" = "1" ] && [ "$sdnse_port" != "$sdns_port" ] ; then
        Check_port "$sdnse_port" || return 1
    fi

    Change_dnsmasq
    Change_adbyby
    echo "$hosts_type" >> "$smartdns_Ini"
    if [ "$sdns_redirect" = 0 ] ; then
        logger -t "SmartDNS" "SmartDNS 使用 $sdns_port 端口"
        [ "$sdnse_enable" = 1 ] && logger -t "SmartDNS" "SmartDNS 使用 $sdnse_port 端口"
    fi
    Change_iptable
    sdns_redirected="$sdns_redirect"
    echo "$sdns_redirected" >> "$smartdns_Ini"
    echo "$sdns_port" >> "$smartdns_Ini"
    echo "$sdnse_port" >> "$smartdns_Ini"

    rm -f /tmp/sdnsipset.conf
    args=""
    logger -t "SmartDNS" "创建配置文件..."
    ipset -N smartdns hash:net >/dev/null 2>&1

    Get_sdns_conf
    # 只剔除纯注释行（注释里的 bind 等示例不能当配置生效）
    for f in "$smartdns_address_Conf" "$smartdns_blacklist_Conf" "$smartdns_whitelist_Conf" ; do
        [ -f "$f" ] && grep -v '^[[:space:]]*#' "$f" | grep -v '^[[:space:]]*$' >> "$smartdns_tmp_Conf"
    done

    # smartdns_custom.conf 由 UI 维护，允许用户自由填写；但它同时含
    # 注释掉的 bind/cache 示例，且用户误写的 bind/cache-size/cache-file
    # 会与上面生成的值冲突（后出现的 bind 会被 smartdns 以
    # "already configured, skip" 丢弃，cache-size 重复取后者）。
    # 因此这里屏蔽三件事：注释行、bind/bind-tcp、cache 相关重复项，
    # 其余（conf-file/domain-rules/server 等）照常生效，并写日志提示。
    if [ -f "$smartdns_custom_Conf" ] ; then
        sed -e 's/[[:space:]]*$//' "$smartdns_custom_Conf" \
            | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' \
            | grep -viE '^(bind|bind-tcp|cache-size|cache-file|cache-persist|cache-checkpoint-time|server-name)([[:space:]]|$)' \
            >> "$smartdns_tmp_Conf"

        blocked=$(sed -e 's/[[:space:]]*$//' "$smartdns_custom_Conf" \
            | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' \
            | grep -iE '^(bind|bind-tcp|cache-size|server-name)([[:space:]]|$)' \
            | sed 's/[[:space:]].*//' | sort -u | tr '\n' ' ')
        [ -n "$blocked" ] && logger -t "SmartDNS" \
            "自定义配置中的 ${blocked}与页面设置冲突，已忽略（请改用页面上的对应选项）"
    fi
    sed -i '/my\.router/d' "$smartdns_tmp_Conf"
    [ -n "$IPS4" ] && echo "domain-rules /my.router/ -c none -a $IPS4 -d no" >> "$smartdns_tmp_Conf"

    # 去重（同一项保留首次出现），写到 /etc/storage 供下次启动参考
    awk '!x[$0]++' "$smartdns_tmp_Conf" > "$smartdns_Conf"

    # 先做一次语法自检，配置错误时不要污染 dnsmasq。
    # 注意：smartdns 的 -x 是 "verbose screen"（前台详细输出），不是
    # 校验后退出——它同样会绑定端口并常驻。所以只能让它短暂跑一下。
    # 判定依据看日志而不是退出码：
    #   * 起不来（端口被占/配置非法）时进程会自行退出，且日志非空；
    #   * 但 pdnsd 兼容下的端口分配、以及 ppp/br0 还没就绪时 bind 失败
    #     也可能让老脚本误判，故只有出现明确的语法错误才报警。
    #   * 日志为空 = 解析完配置、开始绑定后被杀，视为通过。
    :>/tmp/smartdns_check.log
    "$smartdns_Bin" -c "$smartdns_Conf" -x >/tmp/smartdns_check.log 2>&1 &
    check_pid=$!
    sleep 1
    if kill -0 "$check_pid" 2>/dev/null ; then
        kill -9 "$check_pid" >/dev/null 2>&1
        wait "$check_pid" 2>/dev/null
    elif [ -s /tmp/smartdns_check.log ] ; then
        if grep -qi "already running" /tmp/smartdns_check.log 2>/dev/null ; then
            :   # 已有实例在跑，配置无需再校验
        elif grep -qiE "error|invalid|not exist|unknown option|unsupported|syntax" \
                /tmp/smartdns_check.log 2>/dev/null ; then
            errmsg=$(grep -iE "error|invalid|not exist|unknown option|unsupported|syntax" \
                /tmp/smartdns_check.log | head -3 | tr '\n' ' ')
            logger -t "SmartDNS" "配置自检发现错误：$errmsg （详见 /tmp/smartdns_check.log）"
        else
            # 只有 bind/权限类提示，多为上游接口未就绪，交给真正启动时判断
            logger -t "SmartDNS" "自检提示：$(head -2 /tmp/smartdns_check.log | tr '\n' ' ')"
        fi
    fi
    # 自检残留的进程必须先清掉，否则下面起不来
    killall -9 smartdns >/dev/null 2>&1
    sleep 1

    if [ "$sdns_coredump" = "1" ] ; then
        args="$args -S"
    fi

    Restore_dnsmasq

    # 启动 smartdns 进程，日志暂存到 /tmp 便于失败时给出原因
    "$smartdns_Bin" -f -c "$smartdns_Conf" $args >/tmp/smartdns_run.log 2>&1 &
    sleep 2
    smartdns_process=$(pidof smartdns | awk '{ print $1 }')

    # 首次启动若因 conf-file（去广告规则）失败，去掉后重试一次
    if [ "$smartdns_process"x = x ] ; then
        logger -t "SmartDNS" "启动失败..."
        if grep -q "conf-file" "$smartdns_Conf" ; then
            logger -t "SmartDNS" "删除 smartdns.conf 中 conf-file 附加去广告设置，再次启动..."
            logger -t "SmartDNS" "若启动成功，则请检查相关去广告规则格式是否符合SmartDNS要求..."
            sed -i '/^conf-file /d' "$smartdns_Conf"
            "$smartdns_Bin" -f -c "$smartdns_Conf" $args >/tmp/smartdns_run.log 2>&1 &
            sleep 2
            smartdns_process=$(pidof smartdns | awk '{ print $1 }')
        fi
    fi

    if [ "$smartdns_process"x = x ] ; then
        # 把真正的错误原因写进系统日志，而不是丢弃
        errmsg=$(grep -iE "error|fail|invalid|cannot|unable" /tmp/smartdns_run.log 2>/dev/null | head -3 | tr '\n' ' ')
        [ -z "$errmsg" ] && errmsg=$(tail -3 /tmp/smartdns_run.log 2>/dev/null | tr '\n' ' ')
        logger -t "SmartDNS" "启动失败：$errmsg"
        logger -t "SmartDNS" "停用 SmartDNS！请检查其端口配置及自定义设置 ！！！"
        logger -t "SmartDNS" "恢复 DNSmasq 提供 DNS 解析..."
        nvram set sdns_enable=0
        sdns_enable=0
        action="stop"
        # 回滚用"真实添加的端口"，不能用上次记录的旧端口
        sdns_ported="$sdns_port"
        sdnse_ported="$sdnse_port"
        Stop_smartdns
        Restore_dnsmasq
        return 1
    fi

    logger -t "SmartDNS" "进程已启动..."
    # 启动成功后确认 53 是否真的在本进程手里
    if [ "$sdns_port" = "53" ] && ! grep -qi "smartdns" /proc/net/udp 2>/dev/null ; then
        sleep 1
    fi
    return 0
}

Stop_smartdns () {
    killall -9 smartdns >/dev/null 2>&1
    logger -t "SmartDNS" "结束 SmartDNS 进程..."
    Change_adbyby
    Change_dnsmasq
    Change_iptable
    if [ "$dnsmasq_md5" != "$(md5sum  "$dnsmasq_Conf" | awk '{ print $1 }')" ] ; then
        logger -t "SmartDNS" "正在重启 DNSmasq 进程..."
        /sbin/restart_dhcpd >/dev/null 2>&1
        logger -t "SmartDNS" "DNSmasq 进程已重启..."
    fi
    smartdns_process=$(pidof smartdns | awk '{ print $1 }')
    if [ "$smartdns_process"x = x ] && [ "$sdns_enable" = 0 ] ; then
        rm -f "$smartdns_Ini"
        # 停止时把生成出来的配置一并清掉，避免下次启动重复累积
        rm -f "$smartdns_Conf"
        logger -t "SmartDNS" "服务器已停用..."
    fi
}

Main () {
# 【调用各子函数】
    case $action in
    start)
        if [ ! -s "$smartdns_Ini" ] ; then
            logger -t "SmartDNS" "正在启动..."
        fi
        Check_ss
        if [ "$sdns_adblock" = "1" ] ; then
            Start_AD
        fi
        Start_smartdns
        logger -t "SmartDNS" "服务器已启动..."
        sleep 2
        echo 3 > /proc/sys/vm/drop_caches
        ;;
    stop)
        smartdns_process=$(pidof smartdns | awk '{ print $1 }')
        if [ "$smartdns_process"x != x ] ; then
            case $sdns_enable in
            0)
                logger -t "SmartDNS" "停用服务器 ..."
                ;;
            1)
                logger -t "SmartDNS" "重启服务器..."
                ;;
            esac
        fi
        Stop_smartdns
        sleep 2
        echo 3 > /proc/sys/vm/drop_caches
        ;;
    restart)
        if [ "$(nvram get adbyby_enable)" = "1" ] ; then
            [ "$(nvram get adbyby_add)" = "1" ] && hosts_type="SmartDNS"
            [ "$(nvram get adbyby_add)" = "0" ] && hosts_type="DNSmasq"
        else
            hosts_type="0"
        fi
        Check_ss
        Start_smartdns
        logger -t "SmartDNS" "服务器已重启完成.."
        sleep 2
        echo 3 > /proc/sys/vm/drop_caches
        ;;
    reset)
        [ "$sdns_enable" = "1" ] && Change_iptable
        ;;
    *)
        echo "check"
        ;;
    esac
}

Read_ini
Main
