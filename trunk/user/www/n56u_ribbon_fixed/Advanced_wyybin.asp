<!DOCTYPE html>
<html>
<head>
<title><#Web_Title#> - 网易云音乐解锁</title>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">

<link rel="shortcut icon" href="images/favicon.ico">
<link rel="icon" href="images/favicon.png">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/bootstrap.min.css">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/main.css">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/engage.itoggle.css">

<script type="text/javascript" src="/jquery.js"></script>
<script type="text/javascript" src="/bootstrap/js/bootstrap.min.js"></script>
<script type="text/javascript" src="/bootstrap/js/engage.itoggle.min.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/itoggle.js"></script>
<script type="text/javascript" src="/client_function.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script type="text/javascript" src="/help_b.js"></script>
<script>
var $j = jQuery.noConflict();

var wyybin_wl_text = {
	on:  '当前开启：每个请求的完整 JSON 都会写入日志，体积增长很快，排查完请关掉。',
	off: '当前关闭：日志只记启动信息和换源结果，体积很小。'
};

$j(document).ready(function() {

	init_itoggle('wyybin_enable');
	init_itoggle('wyybin_bu');
	init_itoggle('wyybin_ba');
	init_itoggle('wyybin_lv');
	init_itoggle('wyybin_sef');
	init_itoggle('wyybin_wl');
	init_itoggle('wyybin_qq_enable');

	function wyybin_wl_refresh() {
		var on = $j('#wyybin_wl_fake').attr('checked') ? true : ($j('#wyybin_wl_fake').attr('value') == '1');
		$j('#wyybin_wl_hint').text(wyybin_wl_text[on ? 'on' : 'off'])
			.css('color', on ? '#c09853' : '#468847');
	}

	wyybin_wl_refresh();
	// -wl 是几个开关里唯一会持续写盘的，切换后立刻提示当前状态
	$j('#wyybin_wl_on_of').bind('click', function() {
		setTimeout(wyybin_wl_refresh, 60);
	});

});

</script>
<script>
<% wyybin_status(); %>
<% login_state_hook(); %>

function initial(){
	show_banner(2);
	show_menu(5,18,0);
	showmenu();
	fill_status(wyybin_status());
	show_footer();
}
function showmenu(){
showhide_div('alilink', found_app_aliddns());
showhide_div('zelink', found_app_zerotier());
showhide_div('ddlink', found_app_ddnsto());
showhide_div('wilink', found_app_wireguard());
}

function fill_status(status_code){
	var stext = "Unknown";
	if (status_code == 0)
		stext = "<#Stopped#>";
	else if (status_code == 1)
		stext = "<#Running#>";
	$("wyybin_status").innerHTML = '<span class="label label-' + (status_code != 0 ? 'success' : 'warning') + '">' + stext + '</span>';
}

function applyRule(){
	showLoading();

	document.form.action_mode.value = " Restart ";
	document.form.current_page.value = "/Advanced_wyybin.asp";
	document.form.next_page.value = "";

	document.form.submit();
}

function done_validating(action){
	refreshpage();
}

/*
 * 证书查询/生成走 start_apply.htm 的专用动作，不用 apply.cgi：
 *   CheckCertWYYBIN   只读，返回脚本直接吐出的 key=value 文本行
 *   RegenCertWYYBIN   强制删掉现有证书后重签（会换 CA，客户端要重装）
 * 结果里的路径可能来自 U 盘，这里只做 HTML 转义，不做任何解析。
 */
function unm_cert_escape(s){
	return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function unm_cert_show(s, ok, prelude){
	var lines = String(s).split('\n');
	var kept = [];
	for (var i = 0; i < lines.length; i++){
		if (lines[i].length)
			kept.push(unm_cert_escape(lines[i]));
	}
	$j('#unm_cert_result').html(
		(prelude ? '<b>' + prelude + '</b><br>' : '') +
		'<div class="alert ' + (ok ? 'alert-success' : 'alert-error') + '" style="margin:0">' +
		'<pre style="margin:0;border:0;background:transparent;padding:0;font-size:12px;">' +
		kept.join('<br>') + '</pre></div>');
}

function unm_cert_post(action_mode, prelude){
	$j('#unm_cert_result').html('<span style="color:#666">查询中…</span>');
	$j.ajax({
		type: 'post',
		url: '/start_apply.htm',
		data: { action_mode: action_mode },
		dataType: 'text',
		error: function(){
			unm_cert_show('ERR|请求失败，请确认登录尚未过期', false, '');
		},
		success: function(resp){
			unm_cert_show(resp, resp.indexOf('ERR|') !== 0, prelude);
		}
	});
}

function unm_cert_check(){
	unm_cert_post(' CheckCertWYYBIN ', '');
}

function unm_cert_regen(){
	if (!confirm('将按当前「已保存」的路径重新生成整套证书。\n\nCA 会变，装过旧 ca.crt 的客户端需要重新安装。\n确定继续？'))
		return;
	unm_cert_post(' RegenCertWYYBIN ', '已重新生成：');
}

</script>
</head>

<body onload="initial();" onunLoad="return unload_body();">

<div class="wrapper">
	<div class="container-fluid" style="padding-right: 0px">
		<div class="row-fluid">
			<div class="span3"><center><div id="logo"></div></center></div>
			<div class="span9" >
				<div id="TopBanner"></div>
			</div>
		</div>
	</div>

	<div id="Loading" class="popup_bg"></div>

	<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>

	<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">

	<input type="hidden" name="current_page" value="Advanced_wyybin.asp">
	<input type="hidden" name="next_page" value="">
	<input type="hidden" name="next_host" value="">
	<input type="hidden" name="sid_list" value="WYYBIN;">
	<input type="hidden" name="group_id" value="">
	<input type="hidden" name="action_mode" value="">
	<input type="hidden" name="action_script" value="">

	<div class="container-fluid">
		<div class="row-fluid">
			<div class="span3">
				<!--Sidebar content-->
				<!--=====Beginning of Main Menu=====-->
				<div class="well sidebar-nav side_nav" style="padding: 0px;">
					<ul id="mainMenu" class="clearfix"></ul>
					<ul class="clearfix">
						<li>
							<div id="subMenu" class="accordion"></div>
						</li>
					</ul>
				</div>
			</div>

			<div class="span9">
				<!--Body content-->
				<div class="row-fluid">
					<div class="span12">
						<div class="box well grad_colour_dark_blue">
							<h2 class="box_head round_top"><#menu5_30#> - <#menu5_31#></h2>
							<div class="round_bottom">
							<div>
                            <ul class="nav nav-tabs" style="margin-bottom: 10px;">
								<li id="alilink" style="display:none">
                                    <a href="Advanced_aliddns.asp"><#menu5_23_1#></a>
                                </li>
								<li id="zelink" style="display:none">
                                    <a href="Advanced_zerotier.asp"><#menu5_32_1#></a>
                                </li>
								<li id="ddlink" style="display:none">
                                    <a href="Advanced_ddnsto.asp"><#menu5_34_1#></a>
                                </li>
								<li id="wilink" style="display:none">
                                    <a href="Advanced_wireguard.asp"><#menu5_35_1#></a>
                                </li>
								<li class="active">
                                    <a href="Advanced_wyybin.asp"><#menu5_31_1#></a>
                                </li>
                            </ul>
                        </div>
								<div class="row-fluid">
									<div id="tabMenu" class="submenuBlock"></div>
									<div class="alert alert-info" style="margin: 10px;">
									<p>开启后，本机 UnblockNeteaseMusic 会在网关上提供解锁接口，用于恢复网易云音乐中因版权或地区原因灰掉的歌曲。<br>
									<b>转发模式：</b>开启时客户端无需任何设置（需安装 CA 证书）；关闭时需手工把客户端代理指向本路由器，见下方说明。</p>
									</div>

									<table width="100%" align="center" cellpadding="4" cellspacing="0" class="table">

										<tr> <th><#running_status#></th>
                                            <td id="wyybin_status" colspan="3"></td>
                                        </tr>
										<tr>
										<th width="30%" style="border-top: 0 none;">启用网易云音乐解锁</th>
											<td style="border-top: 0 none;">
													<div class="main_itoggle">
													<div id="wyybin_enable_on_of">
														<input type="checkbox" id="wyybin_enable_fake" <% nvram_match_x("", "wyybin_enable", "1", "value=1 checked"); %><% nvram_match_x("", "wyybin_enable", "0", "value=0"); %>  />
													</div>
												</div>
												<div style="position: absolute; margin-left: -10000px;">
													<input type="radio" value="1" name="wyybin_enable" id="wyybin_enable_1" class="input" value="1" <% nvram_match_x("", "wyybin_enable", "1", "checked"); %> /><#checkbox_Yes#>
													<input type="radio" value="0" name="wyybin_enable" id="wyybin_enable_0" class="input" value="0" <% nvram_match_x("", "wyybin_enable", "0", "checked"); %> /><#checkbox_No#>
												</div>
											</td>

										</tr>

										<tr>
										<th>HTTP 监听端口</th>
											<td>
												<input type="text" class="input" name="wyybin_port" id="wyybin_port" style="width: 100px" value="<% nvram_get_x("", "wyybin_port"); %>" />
												<br>默认 5200，不能与路由器已有服务（80/443/53 等）冲突
											</td>
										</tr>

										<tr>
										<th>HTTPS 监听端口</th>
											<td>
												<input type="text" class="input" name="wyybin_sslport" id="wyybin_sslport" style="width: 100px" value="<% nvram_get_x("", "wyybin_sslport"); %>" />
												<br>默认 5201，服务会自动生成自签证书，客户端需关闭证书校验
											</td>
										</tr>

										<tr>
										<th>转发模式</th>
											<td>
												<select name="wyybin_mode" id="wyybin_mode" class="input" style="width: 150px">
													<option value="0" <% nvram_match_x("", "wyybin_mode", "0", "selected"); %>>关闭（手工设置代理）</option>
													<option value="1" <% nvram_match_x("", "wyybin_mode", "1", "selected"); %>>开启（客户端零配置）</option>
												</select>
												<br>开启后本机会改写 <b>/etc/hosts</b> 并把 <b>music.163.com</b> 劫持到路由器，
												   客户端不用做任何设置即可生效。<br>
												<b>注意：</b>此模式需要把下面「CA 证书」安装到客户端，否则 APP 会因证书不受信任而无法联网。
											</td>
										</tr>

										<tr>
										<th>音源优先级</th>
											<td>
												<select name="wyybin_source" id="wyybin_source" class="input" style="width: 200px">
													<option value="pyncmd" <% nvram_match_x("", "wyybin_source", "pyncmd", "selected"); %>>pyncmd 优先（推荐）</option>
													<option value="pyncmd:kuwo" <% nvram_match_x("", "wyybin_source", "pyncmd:kuwo", "selected"); %>>pyncmd 优先 + 酷我兜底</option>
													<option value="pyncmd:kuwo:kugou:migu:qq" <% nvram_match_x("", "wyybin_source", "pyncmd:kuwo:kugou:migu:qq", "selected"); %>>pyncmd 优先 + 全部音源兜底</option>
													<option value="kuwo" <% nvram_match_x("", "wyybin_source", "kuwo", "selected"); %>>酷我 (kuwo)</option>
													<option value="kugou" <% nvram_match_x("", "wyybin_source", "kugou", "selected"); %>>酷狗 (kugou)</option>
													<option value="migu" <% nvram_match_x("", "wyybin_source", "migu", "selected"); %>>咪咕 (migu)</option>
													<option value="qq" <% nvram_match_x("", "wyybin_source", "qq", "selected"); %>>QQ音乐 (qq)</option>
													<option value="kuwo:kugou" <% nvram_match_x("", "wyybin_source", "kuwo:kugou", "selected"); %>>酷我 + 酷狗</option>
													<option value="kuwo:kugou:migu" <% nvram_match_x("", "wyybin_source", "kuwo:kugou:migu", "selected"); %>>酷我 + 酷狗 + 咪咕</option>
													<option value="kuwo:kugou:migu:qq" <% nvram_match_x("", "wyybin_source", "kuwo:kugou:migu:qq", "selected"); %>>全部四个换源音源</option>
												</select>
												<br>找不到原曲时依次尝试的音源，选项越多越慢但命中率越高<br>
												<b>pyncmd</b> 是第三方网易云取址 API：不做搜索匹配，直接用网易 songId 换一条地址，
												拿到的是网易原文件（320k/mp3），<b>不会把翻唱当原唱</b>。实测周传雄/魏晨等 VIP 歌 10/12 可解。<br>
												它覆盖不到的歌会自动落到后面的换源音源，所以建议用「pyncmd 优先 + 酷我兜底」。
											</td>
										</tr>

										<tr>
										<th>匹配阈值</th>
											<td>
												<input type="text" class="input" name="wyybin_minscore" id="wyybin_minscore" style="width: 100px" value="<% nvram_get_x("", "wyybin_minscore"); %>" placeholder="0.75" />
												<br>0 ~ 1，低于此分的搜索结果一律丢弃，默认 <b>0.75</b>。<br>
												若某个音源根本没有原曲版权（例如周杰伦的多数作品在酷我上只有伴奏/翻唱），
												调低阈值会让翻唱被当成原唱播放，调高则宁愿「无版权」也不放错歌。<br>
												填 <b>0</b> 表示关闭过滤，回到上游的原始行为。
											</td>
										</tr>

										<tr>
										<th>功能开关</th>
											<td>
												<table cellpadding="2" cellspacing="0" border="0" style="width:auto">
													<tr><th style="text-align:left;padding-right:10px"><b>-bu</b> 屏蔽升级提示</th>
														<td><div class="main_itoggle"><div id="wyybin_bu_on_of">
															<input type="checkbox" id="wyybin_bu_fake" <% if nvram_match("wyybin_bu","1") || nvram_get_x("", "wyybin_bu") == "": %>value=1 checked<% elif nvram_match("wyybin_bu","0"): %>value=0<% endif %> />
														</div></div>
														<div style="position: absolute; margin-left: -10000px;">
															<input type="radio" value="1" name="wyybin_bu" id="wyybin_bu_1" class="input" <% if nvram_match("wyybin_bu","1") || nvram_get_x("", "wyybin_bu") == "": %>checked<% endif %> />
															<input type="radio" value="0" name="wyybin_bu" id="wyybin_bu_0" class="input" <% if nvram_match("wyybin_bu","0"): %>checked<% endif %> />
														</div></td></tr>
													<tr><th style="text-align:left;padding-right:10px"><b>-ba</b> 去广告</th>
														<td><div class="main_itoggle"><div id="wyybin_ba_on_of">
															<input type="checkbox" id="wyybin_ba_fake" <% if nvram_match("wyybin_ba","1") || nvram_get_x("", "wyybin_ba") == "": %>value=1 checked<% elif nvram_match("wyybin_ba","0"): %>value=0<% endif %> />
														</div></div>
														<div style="position: absolute; margin-left: -10000px;">
															<input type="radio" value="1" name="wyybin_ba" id="wyybin_ba_1" class="input" <% if nvram_match("wyybin_ba","1") || nvram_get_x("", "wyybin_ba") == "": %>checked<% endif %> />
															<input type="radio" value="0" name="wyybin_ba" id="wyybin_ba_0" class="input" <% if nvram_match("wyybin_ba","0"): %>checked<% endif %> />
														</div></td></tr>
													<tr><th style="text-align:left;padding-right:10px"><b>-lv</b> 本地伪 VIP</th>
														<td><div class="main_itoggle"><div id="wyybin_lv_on_of">
															<input type="checkbox" id="wyybin_lv_fake" <% if nvram_match("wyybin_lv","1") || nvram_get_x("", "wyybin_lv") == "": %>value=1 checked<% elif nvram_match("wyybin_lv","0"): %>value=0<% endif %> />
														</div></div>
														<div style="position: absolute; margin-left: -10000px;">
															<input type="radio" value="1" name="wyybin_lv" id="wyybin_lv_1" class="input" <% if nvram_match("wyybin_lv","1") || nvram_get_x("", "wyybin_lv") == "": %>checked<% endif %> />
															<input type="radio" value="0" name="wyybin_lv" id="wyybin_lv_0" class="input" <% if nvram_match("wyybin_lv","0"): %>checked<% endif %> />
														</div></td></tr>
													<tr><th style="text-align:left;padding-right:10px"><b>-sef</b> 解锁音效</th>
														<td><div class="main_itoggle"><div id="wyybin_sef_on_of">
															<input type="checkbox" id="wyybin_sef_fake" <% if nvram_match("wyybin_sef","1") || nvram_get_x("", "wyybin_sef") == "": %>value=1 checked<% elif nvram_match("wyybin_sef","0"): %>value=0<% endif %> />
														</div></div>
														<div style="position: absolute; margin-left: -10000px;">
															<input type="radio" value="1" name="wyybin_sef" id="wyybin_sef_1" class="input" <% if nvram_match("wyybin_sef","1") || nvram_get_x("", "wyybin_sef") == "": %>checked<% endif %> />
															<input type="radio" value="0" name="wyybin_sef" id="wyybin_sef_0" class="input" <% if nvram_match("wyybin_sef","0"): %>checked<% endif %> />
														</div></td></tr>
													<tr><th style="text-align:left;padding-right:10px"><b>-wl</b> 打印请求全文</th>
														<td><div class="main_itoggle"><div id="wyybin_wl_on_of">
															<input type="checkbox" id="wyybin_wl_fake" <% if nvram_match("wyybin_wl","1"): %>value=1 checked<% elif nvram_match("wyybin_wl","0") || nvram_get_x("", "wyybin_wl") == "": %>value=0<% endif %> />
														</div></div>
														<div style="position: absolute; margin-left: -10000px;">
															<input type="radio" value="1" name="wyybin_wl" id="wyybin_wl_1" class="input" <% if nvram_match("wyybin_wl","1"): %>checked<% endif %> />
															<input type="radio" value="0" name="wyybin_wl" id="wyybin_wl_0" class="input" <% if nvram_match("wyybin_wl","0") || nvram_get_x("", "wyybin_wl") == "": %>checked<% endif %> />
														</div></td></tr>
												</table>
												<br>未设置时按默认值：<b>-bu -ba -lv -sef 开启，-wl 关闭</b>。<br>
												<b>-wl</b> 会把每个请求和响应的完整 JSON 写进 <b>/tmp/unblockneteasemusic.log</b>，
												跑几小时就能写满内存盘，排查完请及时关掉（脚本每次启动时会把日志截断到最近 8MB）。
											</td>
										</tr>

										<tr>
										<th>QQ 音源</th>
											<td>
												<div class="main_itoggle"><div id="wyybin_qq_enable_on_of">
													<input type="checkbox" id="wyybin_qq_enable_fake" <% if nvram_match("wyybin_qq_enable","1"): %>value=1 checked<% else %>value=0<% endif %> />
												</div></div>
												<div style="position: absolute; margin-left: -10000px;">
													<input type="radio" value="1" name="wyybin_qq_enable" id="wyybin_qq_enable_1" class="input" <% if nvram_match("wyybin_qq_enable","1"): %>checked<% endif %> />
													<input type="radio" value="0" name="wyybin_qq_enable" id="wyybin_qq_enable_0" class="input" <% if !nvram_match("wyybin_qq_enable","1"): %>checked<% endif %> />
												</div>
											</td>
										</tr>

										<tr>
										<th>附加启动参数</th>
											<td>
												<input type="text" class="input" name="wyybin_extra" id="wyybin_extra" style="width: 300px" value="<% nvram_get_x("", "wyybin_extra"); %>" />
												<br>留空即使用默认值。可用参数：<b>-e</b> 替换播放地址（固件已内置转发支持）、<b>-b</b> 强制最高音质、<b>-lv</b> 本地 VIP、<b>-sef</b> 解锁音效、<b>-ba</b> 屏蔽广告、<b>-sl N</b> 搜索数量(0-3)
											</td>
										</tr>

										<tr>
										<th>证书目录</th>
											<td>
												<input type="text" class="input" name="wyybin_cert" id="wyybin_cert" style="width: 340px" value="<% nvram_get_x("", "wyybin_cert"); %>" placeholder="/etc/storage/unblockneteasemusic" />
												<br>留空即默认目录 <b>/etc/storage/unblockneteasemusic</b>。
												它在 <b>/etc/storage</b> 持久化分区里，<b>重启、刷固件都不会丢</b>。<br>
												想放到 U 盘就填如 <b>/media/UDISK/unm</b>（挂载点见「USB 应用 - 磁盘」页）。
												只写相对路径时按相对默认目录处理。
											</td>
										</tr>

										<tr>
										<th>目录内需要的文件</th>
											<td>
												<table cellpadding="3" cellspacing="0" border="0" style="width:auto">
													<tr><th style="text-align:left;padding-right:12px"><b>ca.crt</b></th>
														<td>自签根证书，<b>装到客户端</b>的就是这个</td></tr>
													<tr><th style="text-align:left;padding-right:12px"><b>ca.key</b></th>
														<td>根证书私钥，由它签发服务器证书</td></tr>
													<tr><th style="text-align:left;padding-right:12px"><b>server.crt</b></th>
														<td>服务器证书，供本机 HTTPS 端口使用</td></tr>
													<tr><th style="text-align:left;padding-right:12px"><b>server.key</b></th>
														<td>服务器证书私钥</td></tr>
												</table>
												<br>这 4 个文件名固定，<b>有效期都是 3650 天</b>，四个齐全才算一套可用证书；
												缺少任何一个都会按「目录不完整」处理并重新生成。<br>
												<b>ca.srl</b> / <b>server.csr</b> / <b>ext.cnf</b> 是签发过程中的临时文件，可以删掉。<br>
												<b>目录怎么来：</b>第一次启动服务时脚本会在该目录自动生成这四个文件；
												也可以自己用 openssl 签一套放进目录，只要 <b>server.crt 由 ca.crt 对应的私钥签发</b>即可。
											</td>
										</tr>

										<tr>
										<th>证书状态</th>
											<td>
												<input class="btn btn-info" type="button" value="检查证书" onclick="unm_cert_check()" />
												&nbsp;
												<input class="btn" type="button" value="按当前设置重新生成" onclick="unm_cert_regen()" />
												<div id="unm_cert_result" style="margin-top: 8px; line-height: 1.6;"></div>
												<br>
												<b>复用规则：</b>证书一旦生成就<b>不再改变</b>，客户端装过一次 <b>ca.crt</b> 之后一直有效；<br>
												只有四个文件齐全且都没过期才复用，服务器证书在到期前 30 天自动重签（<b>CA 不变，客户端无需重装</b>）；<br>
												CA 本身也过期或损坏时才会整套重签，此时客户端需要重新安装 <b>ca.crt</b>。<br>
												<b>注意：</b>改完目录请先点「应用」让服务重启，再点「检查证书」——检查读的是已保存的配置。
											</td>
										</tr>

										<tr>
											<td colspan="4" style="border-top: 0 none;">
												<br />
												<center><input class="btn btn-primary" style="width: 219px" type="button" value="<#CTL_apply#>" onclick="applyRule()" /></center>
											</td>
										</tr>
</table>

									<div class="alert alert-warning" style="margin: 10px;">
									<p><b>两种用法</b><br>
									<b>一、转发模式开启（推荐）：</b>客户端什么都不用设置，本机自动把网易云音乐的域名指到路由器。
									需要把证书目录里的 <b>ca.crt</b>（默认在 <b>/etc/storage/unblockneteasemusic/ca.crt</b>）装到客户端并设为受信任根证书
									（安卓 7+ 还需装到「系统凭证」或用 Magisk 模块，iOS 需在「关于本机 → 证书信任设置」里手动开启）。<br>
									<b>二、转发模式关闭：</b>手工把客户端代理指向本路由 —— 手机 Wi-Fi 里设「HTTP 代理」= 本路由 IP + 上面的 HTTP 端口；
									电脑用 <b>Proxy SwitchyOmega</b> 等工具只把网易云音乐的域名转发过来。<br>
									<b>提示：</b>只设置代理并不会解锁 VIP，它只恢复「因版权/地区灰掉」的曲目，不能替代会员。</p>
									</div>

								</div>
							</div>
						</div>
					</div>
				</div>
			</div>
		</div>
	</div>

	</form>

	<div id="footer"></div>
</div>
</body>
</html>
