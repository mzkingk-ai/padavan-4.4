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

$j(document).ready(function() {

	init_itoggle('wyybin_enable');

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
												<select name="wyybin_source" id="wyybin_source" class="input" style="width: 150px">
													<option value="kuwo" <% nvram_match_x("", "wyybin_source", "kuwo", "selected"); %>>酷我 (kuwo)</option>
													<option value="kugou" <% nvram_match_x("", "wyybin_source", "kugou", "selected"); %>>酷狗 (kugou)</option>
													<option value="migu" <% nvram_match_x("", "wyybin_source", "migu", "selected"); %>>咪咕 (migu)</option>
													<option value="qq" <% nvram_match_x("", "wyybin_source", "qq", "selected"); %>>QQ音乐 (qq)</option>
													<option value="kuwo|kugou" <% nvram_match_x("", "wyybin_source", "kuwo|kugou", "selected"); %>>酷我 + 酷狗</option>
													<option value="kuwo|kugou|migu" <% nvram_match_x("", "wyybin_source", "kuwo|kugou|migu", "selected"); %>>酷我 + 酷狗 + 咪咕</option>
													<option value="kuwo|kugou|migu|qq" <% nvram_match_x("", "wyybin_source", "kuwo|kugou|migu|qq", "selected"); %>>全部四个音源</option>
												</select>
												<br>找不到原曲时依次尝试的音源，选项越多越慢但命中率越高
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
										<th>附加启动参数</th>
											<td>
												<input type="text" class="input" name="wyybin_extra" id="wyybin_extra" style="width: 300px" value="<% nvram_get_x("", "wyybin_extra"); %>" />
												<br>留空即使用默认值。可用参数：<b>-e</b> 替换播放地址（固件已内置转发支持）、<b>-b</b> 强制最高音质、<b>-lv</b> 本地 VIP、<b>-sef</b> 解锁音效、<b>-ba</b> 屏蔽广告、<b>-sl N</b> 搜索数量(0-3)
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
									需要把路由器上的 <b>/etc/storage/unblockneteasemusic/ca.crt</b> 装到客户端并设为受信任根证书
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
