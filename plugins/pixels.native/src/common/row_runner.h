#ifndef FX_NATIVE_ROW_RUNNER_H
#define FX_NATIVE_ROW_RUNNER_H
// 行切分：把「一段纯逐像素的活」按行切成 N 块并行。
//
// 只有这一种并行方式，是因为所有图元的写域都是**互不重叠的行区间**：
// 一旦某个算子需要跨行读改写（比如 IIR 模糊），它就不能用这个模板，
// 而必须显式写串行 —— 这个约束是刻意的，别为了「省一次重构」放宽它。

#include "common/counters.h"
#include "common/prelude.h"

#include <thread>

namespace fx {

/// 按行切分。threads<=1 时直接串行（调用方在预渲染线程里就是这么传的）。
/// 阈值沿用 GDScript 侧的经验值：每线程至少 ~2048 像素才划算，
/// 更少时线程唤醒与 join 的开销会吃掉收益。
template <typename F>
void for_rows(int rows, int width, int threads, F fn) {
	int n = threads;
	if (n > 1) {
		int by_pixels = (rows * width) / 2048;
		n = std::min(n, by_pixels);
		n = std::min(n, 64);
	}
	if (n <= 1 || rows < 8) {
		set_threads(1);
		fn(0, rows);
		return;
	}
	set_threads(n);
	int chunk = (rows + n - 1) / n;
	std::vector<std::thread> pool;
	pool.reserve(n);
	for (int i = 0; i < n; i++) {
		int y0 = i * chunk;
		int y1 = std::min(rows, y0 + chunk);
		if (y0 >= y1) {
			break;
		}
		pool.emplace_back([&fn, y0, y1]() { fn(y0, y1); });
	}
	for (auto &t : pool) {
		t.join();
	}
}

} // namespace fx

#endif // FX_NATIVE_ROW_RUNNER_H
