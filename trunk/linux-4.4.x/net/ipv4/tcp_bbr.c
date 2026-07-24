/* Simplified BBR congestion control for kernel 4.4 backport
 *
 * BBR congestion control computes the sending rate based on the delivery
 * rate (throughput) estimated from ACKs.
 *
 *   bottleneck_bandwidth = windowed_max(delivered / elapsed, 10 round trips)
 *   min_rtt = windowed_min(rtt, 10 seconds)
 *   pacing_rate = pacing_gain * bottleneck_bandwidth
 *   cwnd = max(cwnd_gain * bottleneck_bandwidth * min_rtt, 4)
 *
 * Based on Google BBR (v1) from kernel 4.9, simplified for backport.
 */
#include <linux/module.h>
#include <net/tcp.h>
#include <linux/win_minmax.h>

#define BW_SCALE 24
#define BW_UNIT (1 << BW_SCALE)
#define BBR_SCALE 8
#define BBR_UNIT (1 << BBR_SCALE)

enum bbr_mode {
	BBR_STARTUP,
	BBR_DRAIN,
	BBR_PROBE_BW,
	BBR_PROBE_RTT,
};

struct bbr {
	u32	min_rtt_us;
	u32	min_rtt_stamp;
	u32	probe_rtt_done_stamp;
	struct minmax bw;
	u32	rtt_cnt;
	u32     next_rtt_delivered;
	u32     mode:3,
		prev_ca_state:3,
		packet_conservation:1,
		restore_cwnd:1,
		round_start:1,
		idle_restart:1,
		probe_rtt_round_done:1,
		unused:21;
	u32	pacing_gain:10,
		cwnd_gain:10,
		full_bw_cnt:3,
		cycle_idx:3,
		unused_b:6;
	u32	prior_cwnd;
	u32	full_bw;
};

static const int bbr_high_gain = BBR_UNIT * 2885 / 1000 + 1;
static const int bbr_drain_gain = BBR_UNIT * 1000 / 2885;
static const int bbr_cwnd_gain  = BBR_UNIT * 2;
static const int bbr_pacing_gain[] = {
	BBR_UNIT * 5 / 4, BBR_UNIT * 3 / 4,
	BBR_UNIT, BBR_UNIT, BBR_UNIT,
	BBR_UNIT, BBR_UNIT, BBR_UNIT
};
static const u32 bbr_cwnd_min_target = 4;
static const u32 bbr_full_bw_thresh = BBR_UNIT * 5 / 4;
static const u32 bbr_full_bw_cnt = 3;
static const int bbr_bw_rtts = 10;
static const u32 bbr_min_rtt_win_sec = 10;
static const u32 bbr_probe_rtt_mode_ms = 200;

static u32 bbr_max_bw(const struct sock *sk)
{
	const struct bbr *bbr = inet_csk_ca(sk);
	return minmax_get(&bbr->bw);
}

static u32 bbr_bw(const struct sock *sk)
{
	return bbr_max_bw(sk);
}

static u64 bbr_rate_bytes_per_sec(struct sock *sk, u64 rate, int gain)
{
	rate *= tcp_mss_to_mtu(sk, tcp_sk(sk)->mss_cache);
	rate *= gain;
	rate >>= BBR_SCALE;
	rate *= USEC_PER_SEC;
	return rate >> BW_SCALE;
}

static void bbr_set_pacing_rate(struct sock *sk, u32 bw, int gain)
{
	u64 rate = bbr_rate_bytes_per_sec(sk, bw, gain);

	rate = min_t(u64, rate, sk->sk_max_pacing_rate);
	if (bbr_high_gain == 0 || rate > sk->sk_pacing_rate)
		sk->sk_pacing_rate = rate;
}

static void bbr_init(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	bbr->prior_cwnd = 0;
	tp->snd_ssthresh = TCP_INFINITE_SSTHRESH;
	bbr->rtt_cnt = 0;
	bbr->next_rtt_delivered = 0;
	bbr->prev_ca_state = TCP_CA_Open;
	bbr->packet_conservation = 0;
	bbr->probe_rtt_done_stamp = 0;
	bbr->probe_rtt_round_done = 0;
	bbr->min_rtt_us = tcp_min_rtt(tp);
	bbr->min_rtt_stamp = tcp_time_stamp;
	minmax_reset(&bbr->bw, bbr->rtt_cnt, 0);
	bbr->restore_cwnd = 0;
	bbr->round_start = 0;
	bbr->idle_restart = 0;
	bbr->full_bw_cnt = 0;
	bbr->full_bw = 0;
	bbr->cycle_idx = 0;
	bbr->mode = BBR_STARTUP;
	bbr->pacing_gain = bbr_high_gain;
	bbr->cwnd_gain = bbr_high_gain;
}

static void bbr_cwnd_event(struct sock *sk, enum tcp_ca_event event)
{
	struct bbr *bbr = inet_csk_ca(sk);

	if (event == CA_EVENT_TX_START)
		bbr->idle_restart = 1;
}

/* BBR uses cong_control() for congestion avoidance;
 * this stub is required by kernel 4.4 registration.
 */
static void bbr_cong_avoid(struct sock *sk, u32 ack, u32 acked)
{
}

static u32 bbr_ssthresh(struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	bbr->packet_conservation = 1;
	bbr->restore_cwnd = 1;
	bbr->prior_cwnd = tcp_sk(sk)->snd_cwnd;
	return max(tcp_sk(sk)->snd_cwnd >> 1, 2U);
}

static u32 bbr_undo_cwnd(struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	bbr->full_bw = 0;
	bbr->full_bw_cnt = 0;
	bbr->packet_conservation = 0;
	return max(tcp_sk(sk)->snd_cwnd, bbr->prior_cwnd);
}

static void bbr_set_state(struct sock *sk, u8 new_state)
{
	struct bbr *bbr = inet_csk_ca(sk);

	if (new_state == TCP_CA_Loss) {
		bbr->prev_ca_state = TCP_CA_Loss;
		bbr->full_bw = 0;
		bbr->round_start = 1;
	}
}

static size_t bbr_get_info(struct sock *sk, u32 ext, int *attr,
			    union tcp_cc_info *info)
{
	return 0;
}

static void bbr_update_model(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	u64 bw;

	if (rs->delivered < 0 || rs->interval_us <= 0)
		return;

	/* Compute bandwidth delivered / interval */
	bw = (u64)rs->delivered * BW_UNIT;
	do_div(bw, rs->interval_us);

	/* Update windowed max bandwidth filter */
	minmax_running_max(&bbr->bw, bbr_bw_rtts, bbr->rtt_cnt, (u32)bw);

	/* Detect round */
	if (rs->acked_sacked && tp->delivered > bbr->next_rtt_delivered) {
		bbr->rtt_cnt++;
		bbr->next_rtt_delivered = tp->delivered;
		bbr->round_start = 1;
	} else {
		bbr->round_start = 0;
	}

	/* Update min_rtt */
	if (tcp_min_rtt(tp) && bbr->min_rtt_us > tcp_min_rtt(tp))
		bbr->min_rtt_us = tcp_min_rtt(tp);
}

static void bbr_cong_control(struct sock *sk, u32 ack, struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	u32 bw_val, cwnd;

	bbr_update_model(sk, rs);

	bw_val = bbr_bw(sk);
	if (!bw_val)
		return;

	/* BDP-based cwnd: target_cwnd = bw * min_rtt / mss */
	cwnd = bw_val * bbr->min_rtt_us / (USEC_PER_SEC * BW_UNIT / tp->mss_cache);
	cwnd = cwnd * bbr->cwnd_gain / BBR_UNIT;
	cwnd = max(cwnd, bbr_cwnd_min_target);

	tp->snd_cwnd = cwnd;
	bbr_set_pacing_rate(sk, bw_val, bbr->pacing_gain);
}

static struct tcp_congestion_ops tcp_bbr_cong_ops __read_mostly = {
	.flags		= TCP_CONG_NON_RESTRICTED,
	.name		= "bbr",
	.owner		= THIS_MODULE,
	.init		= bbr_init,
	.cong_control	= bbr_cong_control,
	.cong_avoid	= bbr_cong_avoid,
	.undo_cwnd	= bbr_undo_cwnd,
	.cwnd_event	= bbr_cwnd_event,
	.ssthresh	= bbr_ssthresh,
	.get_info	= bbr_get_info,
	.set_state	= bbr_set_state,
};

static int __init bbr_register(void)
{
	BUILD_BUG_ON(sizeof(struct bbr) > ICSK_CA_PRIV_SIZE);
	return tcp_register_congestion_control(&tcp_bbr_cong_ops);
}

static void __exit bbr_unregister(void)
{
	tcp_unregister_congestion_control(&tcp_bbr_cong_ops);
}

module_init(bbr_register);
module_exit(bbr_unregister);

MODULE_AUTHOR("Van Jacobson <vanj@google.com>");
MODULE_AUTHOR("Neal Cardwell <ncardwell@google.com>");
MODULE_LICENSE("Dual BSD/GPL");
MODULE_DESCRIPTION("TCP BBR (Bottleneck Bandwidth and RTT) - simplified backport");
