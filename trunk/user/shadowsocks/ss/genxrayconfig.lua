local cjson = require "cjson"
local server_section = arg[1]
local proto = arg[2]
local local_port = arg[3] or "0"
local socks_port = arg[4] or "0"
local ssrindext = io.popen("dbus get ssconf_basic_json_" .. server_section)
local servertmp = ssrindext:read("*all")
local server = cjson.decode(servertmp)

-- 构建 inbounds 数组
local inbounds = {}

-- 判断是否为合并模式（TCP + UDP 共用一个 xray 进程）
local is_both = (proto == "both")

-- 1) dokodemo-door 入站（透明代理）
if local_port ~= "0" then
	if is_both then
		-- 合并模式：同时添加 TCP 和 UDP 入站
		table.insert(inbounds, {
			port = tonumber(local_port),
			protocol = "dokodemo-door",
			settings = {
				network = "tcp",
				followRedirect = true
			},
			sniffing = {
				enabled = true,
				destOverride = { "http", "tls" }
			}
		})
		table.insert(inbounds, {
			port = tonumber(local_port),
			protocol = "dokodemo-door",
			settings = {
				network = "udp",
				followRedirect = true
			},
			sniffing = {
				enabled = true,
				destOverride = { "http", "tls" }
			}
		})
	else
		table.insert(inbounds, {
			port = tonumber(local_port),
			protocol = "dokodemo-door",
			settings = {
				network = proto,
				followRedirect = true
			},
			sniffing = {
				enabled = true,
				destOverride = { "http", "tls" }
			}
		})
	end
end

-- 2) socks 入站（可选）
if (proto == "tcp" or is_both) and socks_port ~= "0" then
	table.insert(inbounds, {
		protocol = "socks",
		port = tonumber(socks_port),
		settings = {
			auth = "noauth",
			udp = true
		}
	})
end

-- 构建 outbounds 数组
local outbounds = {}

-- 1) VLESS 主出站
table.insert(outbounds, {
	protocol = "vless",
	tag = "proxy",
	settings = {
		vnext = {
			{
				address = server.server,
				port = tonumber(server.server_port),
				users = {
					{
						id = server.vmess_id,
						flow = (server.flow == '1') and "xtls-rprx-direct"
							or ((server.flow == '2') and "xtls-rprx-splice"
							or ((server.flow == '3') and "xtls-rprx-vision" or "")),
						level = tonumber(server.alter_id),
						encryption = server.security
					}
				}
			}
		}
	},
	streamSettings = {
		network = server.transport,
		security = (server.tls == '1') and "tls"
			or ((server.tls == '2') and "xtls"
			or ((server.tls == '3') and "reality" or "none")),

		tlsSettings = (server.tls == '1') and {
			allowInsecure = (server.insecure ~= "0") and true or false,
			serverName = server.tls_host,
			fingerprint = server.fingerprint
		} or nil,

		xtlsSettings = (server.tls == '2') and {
			allowInsecure = (server.insecure ~= "0") and true or false,
			serverName = server.tls_host,
			fingerprint = server.fingerprint
		} or nil,

		realitySettings = (server.tls == '3') and {
			allowInsecure = (server.insecure ~= "0") and true or false,
			serverName = server.tls_host,
			publicKey = server.public_key,
			shortId = server.short_id,
			fingerprint = server.fingerprint
		} or nil,

		tcpSettings = (server.transport == "tcp" and server.tls ~= '2') and {
			header = {
				type = server.tcp_guise,
				request = {
					path = server.http_path or {"/"},
					headers = {
						Host = server.http_host or {}
					}
				}
			}
		} or nil,

		kcpSettings = (server.transport == "kcp") and {
			mtu = tonumber(server.mtu),
			tti = tonumber(server.tti),
			uplinkCapacity = tonumber(server.uplink_capacity),
			downlinkCapacity = tonumber(server.downlink_capacity),
			congestion = (server.congestion == "1") and true or false,
			readBufferSize = tonumber(server.read_buffer_size),
			writeBufferSize = tonumber(server.write_buffer_size),
			header = { type = server.kcp_guise }
		} or nil,

		wsSettings = (server.transport == "ws") and (server.ws_path ~= nil or server.ws_host ~= nil) and {
			path = server.ws_path,
			headers = (server.ws_host ~= nil) and {
				Host = server.ws_host
			} or nil
		} or nil,

		grpcSettings = (server.transport == "grpc") and (server.grpc_path ~= nil) and {
			serviceName = server.grpc_path
		} or nil,

		httpSettings = (server.transport == "h2") and {
			path = server.h2_path,
			host = server.h2_host
		} or nil,

		quicSettings = (server.transport == "quic") and {
			security = server.quic_security,
			key = server.quic_key,
			header = { type = server.quic_guise }
		} or nil
	},
	mux = {
		enabled = (server.mux == "1") and true or false,
		concurrency = tonumber(server.concurrency)
	}
})

-- 2) freedom 直连出站
table.insert(outbounds, {
	protocol = "freedom",
	tag = "direct",
	settings = { keep = "" }
})

local xray = {
	log = {
		loglevel = "warning"
	},
	inbounds = inbounds,
	outbounds = outbounds
}

print(cjson.encode(xray))
