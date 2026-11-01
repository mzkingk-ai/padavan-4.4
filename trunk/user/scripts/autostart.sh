#!/bin/sh
#
# Copyright (C) 2022 TurBoTse <860018505@qq.com>
#
#nvram set ntp_ready=0

mkdir -p /tmp/dnsmasq.dom
logger -t "防止 DNSmasq 启动失败，创建/tmp/dnsmasq.dom/"

# ap relay monitor [simonchen]
if [ ! -x /etc/storage/sh_ezscript.sh ]; then
	cp /etc_ro/sh_ezscript.sh /etc/storage/sh_ezscript.sh
fi
if [ -x /etc/storage/ap_script.sh ]; then
	/etc/storage/ap_script.sh >/dev/null 2>&1 &
else
	cp /etc_ro/ap_script.sh /etc/storage/ap_script.sh
fi
smartdns_conf="/etc/storage/smartdns_custom.conf"
dnsmasq_Conf="/etc/storage/dnsmasq/dnsmasq.conf"
smartdns_Ini="/etc/storage/smartdns_conf.ini"
sdns_port=$(nvram get sdns_port)

logger -t "自动启动" "正在检查路由是否已连接互联网..."
count=0
while :
do
	ping -c 1 -W 1 -q 223.5.5.5 1>/dev/null 2>&1
	if [ "$?" == "0" ]; then
		break
	fi
	sleep 5
	ping -c 1 -W 1 -q baidu.com 1>/dev/null 2>&1
	if [ "$?" == "0" ]; then
		break
	fi
	sleep 5
	count=$((count+1))
	if [ $count -gt 18 ]; then
		break
	fi
done

if [ $(nvram get pppoemwan_enable) = 1 ] ; then
sleep 20
fi

if [ $(nvram get sqm_enable) = 1 ] ; then
sleep 30
logger -t "自动启动" "正在启动 SQM QOS..."
/usr/lib/sqm/run.sh
fi

if [ $(nvram get adbyby_enable) = 1 ] ; then
logger -t "自动启动" "正在启动 Adbyby plus..."
/usr/bin/adbyby.sh start
fi

if [ $(nvram get adg_enable) = 1 ] ; then
logger -t "自动启动" "正在启动 adguardhome..."
/usr/bin/adguardhome.sh start
fi

if [ $(nvram get ss_enable) = 1 ] ; then
logger -t "自动启动" "正在启动科学上网..."
/usr/bin/shadowsocks.sh start
fi

# 网易云解锁必须排在 SmartDNS 之前：它的转发模式（wyybin_mode=1）是往
# dnsmasq 用户配置写 address=/music.163.com/<本机>/ 这类劫持规则，而 SmartDNS
# 只在启动那一刻读一遍那份文件（smartdns.sh 的 Get_sdns_conf）。反过来先起
# SmartDNS 的话，这一轮写进去的规则不会被接管，要等下次重启才生效。
if [ $(nvram get wyybin_enable) = 1 ] ; then
logger -t "自动启动" "正在启动网易云音乐解锁..."
/usr/bin/unblockneteasemusic.sh start
fi

if [ $(nvram get sdns_enable) = 1 ] ; then
   if [ -f "$smartdns_conf" ] ; then
       sed -i '/去广告/d' $smartdns_conf
       sed -i '/adbyby/d' $smartdns_conf
       sed -i '/no-resolv/d' "$dnsmasq_Conf"
       sed -i '/server=127.0.0.1#'"$sdns_port"'/d' "$dnsmasq_Conf"
       sed -i '/port=0/d' "$dnsmasq_Conf"
       rm  -f "$smartdns_Ini"
   fi
logger -t "自动启动" "正在启动 SmartDNS..."
/usr/bin/smartdns.sh start
# 兜底：万一本轮 wyybin 的劫持规则没能赶在 SmartDNS 启动前写入（例如
# 证书生成耗时把顺序拉长，或 wyybin 上一次启动失败），就在 SmartDNS
# 起来之后补一次重启，让它重新读一遍 dnsmasq.conf 里的 address 规则。
# 只有两个功能都开着、且 wyybin 确实在跑时才做，避免无谓的重启。
if [ $(nvram get wyybin_enable) = 1 ] && [ "$(nvram get wyybin_mode)" = "1" ] && \
   pidof UnblockNeteaseMusic >/dev/null 2>&1 ; then
    logger -t "自动启动" "重启 SmartDNS 以接管网易云解锁的地址劫持..."
    /usr/bin/smartdns.sh stop >/dev/null 2>&1
    /usr/bin/smartdns.sh start >/dev/null 2>&1
fi
fi

if [ $(nvram get aliddns_enable) = 1 ] ; then
logger -t "自动启动" "正在启动阿里ddns..."
/usr/bin/aliddns.sh start
fi

if [ $(nvram get ddnsto_enable) = 1 ] ; then
logger -t "自动启动" "正在启动 ddnsto..."
/usr/bin/ddnsto.sh start
fi

if [ $(nvram get aliyundrive_enable) = 1 ] ; then
logger -t "自动启动" "正在启动阿里云盘..."
/usr/bin/aliyundrive-webdav.sh start
fi

if [ $(nvram get zerotier_enable) = 1 ] ; then
logger -t "自动启动" "正在启动 zerotier..."
/usr/bin/zerotier.sh start
fi

if [ $(nvram get wireguard_enable) = 1 ] ; then
logger -t "自动启动" "正在启动 wireguard..."
/usr/bin/wireguard.sh start
fi

if [ $(nvram get frpc_enable) = 1 ] ; then
logger -t "自动启动" "正在启动frp client..."
/usr/bin/frp.sh start
fi
