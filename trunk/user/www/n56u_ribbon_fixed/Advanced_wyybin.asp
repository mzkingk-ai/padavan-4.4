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
var wyybin_wl_apply = function(){};

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

	// 提到 jQuery 作用域外，initial() 里要用
	wyybin_wl_apply = wyybin_wl_refresh;
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
	// 自定义菜单项要等 showmenu() 把节点建出来才存在，放在后面才找得到
	wyybin_wl_apply();
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

/*
 * 保存流程不用 start_apply.htm + showLoading()。
 *
 * start_apply.htm 的收尾靠「反向调用父窗口」：
 *   page_modified==1 → parent.showLoading(restart_time,"waiting")
 *   page_modified==0 → top_delay_redirect(current_page)
 * 而 page_modified 只有在它自己的 onload 里跑到 done_committing() 才会变成 1，
 * 那个调用又要有实际的 nvram 变化才会被 httpd 吐出来（web_ex.c：
 * 「if (nvram_modified) done_committing(); else no_changes_and_no_committing();」）。
 * 于是两种死法：
 *   没有实际改动 → 不吐 done_committing → page_modified 停在 0 → 走 else 分支，
 *                 而当前页面的 showLoading() 遮罩已经弹出，没有任何人负责收掉；
 *   有实际改动 → parent.showLoading(0,"waiting") → 传了 "waiting" 标志时
 *                 popup.js 不会自动 hideLoading，同样没人收。
 *
 * 本页改为自己发 AJAX：httpd 是单连接串行的，start_apply.htm 内联的
 * update_variables()/asus_nvram_commit()/notify_services() 会把响应一直压到
 * 服务重启完成才返回（wyybin 这几个键的 mask 是 EVM_RESTART_WYYBIN，走
 * notify_rc("restart_wyy") → restart_wyybin()，其中 stop 要跑完脚本、
 * restart_dns 还要 SIGHUP dnsmasq）。因此 ajax 的 success 回来就代表
 * 已保存且重启完毕；出错时延迟一下再冲刷，遮罩一定会被收掉。
 */
function applyRule(){
	setTimeout(function(){ unm_apply_post(); }, 100);
}

function unm_apply_post(){
	showLoading();

	var postdata = {
		current_page:  '/Advanced_wyybin.asp',
		next_page:     '',
		sid_list:      'WYYBIN;',
		group_id:      '',
		action_mode:   ' Restart ',
		action_script: ''
	};
	// 用表单里的实际控件取值，value 与页面上看到的一致；
	// 不手写字段清单，漏一个就会静默不保存。
	jQuery('#ruleForm').find('input,select,textarea').each(function(){
		var n = this.name;
		if (!n || n == 'action_mode' || n == 'current_page' || n == 'next_page')
			return;
		if ((this.type == 'radio' || this.type == 'checkbox') && !this.checked)
			return;
		postdata[n] = jQuery(this).val();
	});

	jQuery.ajax({
		type:     'post',
		url:      '/start_apply.htm',
		data:     postdata,
		dataType: 'text',
		timeout:  60000,
		success:  function(){ unm_apply_done(); },
		error:    function(){ setTimeout(unm_apply_done, 2000); }
	});
}

function unm_apply_done(){
	hideLoading();
	location.href = 'Advanced_wyybin.asp';
}

function done_validating(action){
	unm_apply_done();
}

/*
 * 证书查询/生成走 update.cgi?output=wyybin_cert，映射到 web_ex.c 里的
 * wyybin_cert_hook，响应体是脚本直接吐出的 key=value 文本行。
 * 不要用 start_apply.htm：它命中 mime_handlers 的 "**.htm*" → do_ej，
 * 只做模板渲染、根本不执行提交，AJAX 拿回来的是整页 HTML，
 * 再被塞进 result 区就成了"页面显示一堆 HTML 源码"。
 *   action_mode= CheckCertWYYBIN   只读，检查当前（已保存的）路径
 *   action_mode= RegenCertWYYBIN   强制重签（会换 CA，客户端要重装）
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
		url: '/update.cgi',
		data: { output: 'wyybin_cert', action_mode: action_mode },
		dataType: 'text',
		timeout: 60000,
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
												<br>默认 5201。证书由下方「证书目录」里的自签 CA 签发：把 <b>ca.crt</b> 装到客户端当受信任根证书即可正常校验，
												不装也能用（客户端选择忽略证书错误）——但 CA 换过之后必须重新装。
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
												<br>找不到原曲时用来兜底的音源，<b>全部同时发出、6 秒内谁先给结果用谁</b>；
												选项多不会明显变慢（只多几个并发请求），但命中率更高。<br>
												<b>pyncmd</b> 是第三方网易云取址 API：不做搜索匹配，直接用网易 songId 换一条地址，
												拿到的是网易原文件（320k/mp3），<b>不会把翻唱当原唱</b>。实测周传雄/魏晨等 VIP 歌 10/12 可解。<br>
												pyncmd 与上面的换源音源<b>同时</b>发出：pyncmd 有结果就直接用它（它是网易原曲，优先）；
												没有才按匹配分从换源结果里取最高的一条。所以建议用「pyncmd 优先 + 酷我兜底」。
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
															<input type="checkbox" id="wyybin_bu_fake" <% nvram_match_x("", "wyybin_bu", "1", "value=1 checked"); %><% nvram_match_x("", "wyybin_bu", "0", "value=0"); %> />
														</div></div>
														<div style="position: absolute; margin-left: -10000px;">
															<input type="radio" value="1" name="wyybin_bu" id="wyybin_bu_1" class="input" <% nvram_match_x("", "wyybin_bu", "1", "checked"); %> />
															<input type="radio" value="0" name="wyybin_bu" id="wyybin_bu_0" class="input" <% nvram_match_x("", "wyybin_bu", "0", "checked"); %> />
														</div></td></tr>
													<tr><th style="text-align:left;padding-right:10px"><b>-ba</b> 去广告</th>
														<td><div class="main_itoggle"><div id="wyybin_ba_on_of">
															<input type="checkbox" id="wyybin_ba_fake" <% nvram_match_x("", "wyybin_ba", "1", "value=1 checked"); %><% nvram_match_x("", "wyybin_ba", "0", "value=0"); %> />
														</div></div>
														<div style="position: absolute; margin-left: -10000px;">
															<input type="radio" value="1" name="wyybin_ba" id="wyybin_ba_1" class="input" <% nvram_match_x("", "wyybin_ba", "1", "checked"); %> />
															<input type="radio" value="0" name="wyybin_ba" id="wyybin_ba_0" class="input" <% nvram_match_x("", "wyybin_ba", "0", "checked"); %> />
														</div></td></tr>
													<tr><th style="text-align:left;padding-right:10px"><b>-lv</b> 本地伪 VIP</th>
														<td><div class="main_itoggle"><div id="wyybin_lv_on_of">
															<input type="checkbox" id="wyybin_lv_fake" <% nvram_match_x("", "wyybin_lv", "1", "value=1 checked"); %><% nvram_match_x("", "wyybin_lv", "0", "value=0"); %> />
														</div></div>
														<div style="position: absolute; margin-left: -10000px;">
															<input type="radio" value="1" name="wyybin_lv" id="wyybin_lv_1" class="input" <% nvram_match_x("", "wyybin_lv", "1", "checked"); %> />
															<input type="radio" value="0" name="wyybin_lv" id="wyybin_lv_0" class="input" <% nvram_match_x("", "wyybin_lv", "0", "checked"); %> />
														</div></td></tr>
													<tr><th style="text-align:left;padding-right:10px"><b>-sef</b> 解锁音效</th>
														<td><div class="main_itoggle"><div id="wyybin_sef_on_of">
															<input type="checkbox" id="wyybin_sef_fake" <% nvram_match_x("", "wyybin_sef", "1", "value=1 checked"); %><% nvram_match_x("", "wyybin_sef", "0", "value=0"); %> />
														</div></div>
														<div style="position: absolute; margin-left: -10000px;">
															<input type="radio" value="1" name="wyybin_sef" id="wyybin_sef_1" class="input" <% nvram_match_x("", "wyybin_sef", "1", "checked"); %> />
															<input type="radio" value="0" name="wyybin_sef" id="wyybin_sef_0" class="input" <% nvram_match_x("", "wyybin_sef", "0", "checked"); %> />
														</div></td></tr>
													<tr><th style="text-align:left;padding-right:10px"><b>-wl</b> 打印请求全文</th>
														<td><div class="main_itoggle"><div id="wyybin_wl_on_of">
															<input type="checkbox" id="wyybin_wl_fake" <% nvram_match_x("", "wyybin_wl", "1", "value=1 checked"); %><% nvram_match_x("", "wyybin_wl", "0", "value=0"); %> />
														</div></div>
														<div style="position: absolute; margin-left: -10000px;">
															<input type="radio" value="1" name="wyybin_wl" id="wyybin_wl_1" class="input" <% nvram_match_x("", "wyybin_wl", "1", "checked"); %> />
															<input type="radio" value="0" name="wyybin_wl" id="wyybin_wl_0" class="input" <% nvram_match_x("", "wyybin_wl", "0", "checked"); %> />
														</div>
														<div id="wyybin_wl_hint" style="font-size:12px;margin-top:4px"></div></td></tr>
												</table>
												<br>未设置时按默认值：<b>-bu -ba -lv -sef 开启，-wl 关闭</b>。<br>
												这几个开关对应上游的无值参数（<code>-bu</code> 之类），语义只有「传 = 开，不传 = 关」，
												所以<b>不存在在「附加启动参数」里把它们单独关掉</b>的写法；脚本也会把这几个从附加参数里剔除。<br>
												<b>-wl</b> 会把每个请求和响应的完整 JSON 写进 <b>/tmp/unblockneteasemusic.log</b>，
												跑几小时就能写满内存盘，排查完请及时关掉（脚本每次启动时会把日志截断到最近 8MB）。
											</td>
										</tr>

										<tr>
										<th>QQ 音源</th>
											<td>
												<div class="main_itoggle"><div id="wyybin_qq_enable_on_of">
													<input type="checkbox" id="wyybin_qq_enable_fake" <% nvram_match_x("", "wyybin_qq_enable", "1", "value=1 checked"); %><% nvram_match_x("", "wyybin_qq_enable", "0", "value=0"); %> />
												</div></div>
												<div style="position: absolute; margin-left: -10000px;">
													<input type="radio" value="1" name="wyybin_qq_enable" id="wyybin_qq_enable_1" class="input" <% nvram_match_x("", "wyybin_qq_enable", "1", "checked"); %> />
													<input type="radio" value="0" name="wyybin_qq_enable" id="wyybin_qq_enable_0" class="input" <% nvram_match_x("", "wyybin_qq_enable", "0", "checked"); %> />
												</div>
											</td>
										</tr>

										<tr>
										<th>附加启动参数</th>
											<td>
												<input type="text" class="input" name="wyybin_extra" id="wyybin_extra" style="width: 300px" value="<% nvram_get_x("", "wyybin_extra"); %>" />
												<br>留空即使用默认值。可用参数：<b>-e</b> 替换播放地址（固件已内置转发支持）、<b>-b</b> 强制最高音质、<b>-sl N</b> 搜索数量(0-3)、<b>-insecure</b> TLS 口按明文监听。<br>
												注意：<b>-bu/-ba/-lv/-sef/-wl</b> 已由上面的开关控制，写在这里会被忽略；
												这些是无值参数，写成 <code>-wl=1</code> 或 <code>-wl true</code> 会让程序解析失败直接退出。
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
												<br>这 4 个文件名固定，<b>有效期都是 3650 天</b>。脚本按下面的顺序逐级判断，能少动就少动：<br>
												<b>1.</b> 四个文件齐全、都没过期、且 server.crt 确实由这套 ca.key 签发 → <b>原样复用</b>，什么都不改；<br>
												<b>2.</b> CA 还有效，只是 server.crt 缺失/过期/对不上 → <b>只重签 server.crt</b>，CA 不变，客户端不用重装；<br>
												<b>3.</b> CA 本身缺失/过期/损坏 → <b>整套重签</b>，此时客户端要重新安装 ca.crt。<br>
												重签前会把旧文件挪成 <b>*.bak-unm</b>，失败时自动还原，不会留下半套证书。<br>
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
												<b>两个按钮的作用：</b><br>
												<b>检查证书</b>只读不写——按<b>已保存的</b>目录读文件、看是否过期、核对签发链，结果输出在下方，不会改任何文件。<br>
												<b>按当前设置重新生成</b>会先确认，然后强制重签整套（<b>CA 会变</b>，装过旧 ca.crt 的客户端需要重新安装）；
												失败时自动还原旧证书。<br>
												<b>注意：</b>改完目录请先点「应用」让配置保存，再点「检查证书」——检查读的是已保存的配置。
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
