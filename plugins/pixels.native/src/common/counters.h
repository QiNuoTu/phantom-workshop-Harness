#ifndef FX_NATIVE_COUNTERS_H
#define FX_NATIVE_COUNTERS_H
// 五个 family 共用的统计计数器。
//
// 为什么不是每个类各存一份：诊断面板要回答的是「这一帧走了多少次原生」，
// 分族统计没有意义（同一次求值会横跨多个族）。所以计数器是**进程级**的，
// 与「哪个组件贡献了它」无关 —— 组件的边界在注册表上，不在计数上。

#include "common/prelude.h"

namespace fx {

inline std::atomic<int> g_calls{ 0 };
inline std::atomic<int> g_last_threads{ 1 };
inline std::atomic<long long> g_pixels{ 0 };

inline void count_call(long long p_pixels) {
	g_calls.fetch_add(1);
	g_pixels.fetch_add(p_pixels);
}

inline void set_threads(int p_threads) {
	g_last_threads.store(p_threads);
}

inline Dictionary stats() {
	Dictionary out;
	out["calls"] = g_calls.load();
	out["last_threads"] = g_last_threads.load();
	out["pixels"] = (int64_t)g_pixels.load();
	return out;
}

inline void reset() {
	g_calls.store(0);
	g_pixels.store(0);
	g_last_threads.store(1);
}

} // namespace fx

#endif // FX_NATIVE_COUNTERS_H
