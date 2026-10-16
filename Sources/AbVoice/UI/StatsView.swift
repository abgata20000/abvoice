import SwiftUI

/// 喋り終わってから挿入されるまでの待ち時間が、実際にどのくらいかを見るための画面。
/// 数字はこの Mac に保存している履歴から、その場で集計する。
struct StatsView: View {
    @ObservedObject private var store = LocalHistoryStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.records.isEmpty {
                    Text("まだ記録が無いため統計を出せません。")
                        .foregroundStyle(.secondary)
                } else {
                    latencySection
                    engineSection
                    formatModelSection
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: レイテンシ

    private var latencies: [Int] {
        store.records.map(\.latencyMs).sorted()
    }

    private var latencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("レイテンシ（\(latencies.count) 件）").font(.headline)
            HStack(spacing: 20) {
                stat("平均", average)
                stat("中央値", percentile(0.5))
                stat("p90", percentile(0.9))
                stat("最大", latencies.last ?? 0)
                stat("最小", latencies.first ?? 0)
            }
            Text("録音を止めてから挿入が終わるまでの時間です。Mac の機種と、整形の有無で変わります。")
                .font(.caption).foregroundStyle(.secondary)
            Histogram(values: latencies)
        }
    }

    private var average: Int {
        guard !latencies.isEmpty else { return 0 }
        return latencies.reduce(0, +) / latencies.count
    }

    private func percentile(_ p: Double) -> Int {
        guard !latencies.isEmpty else { return 0 }
        let index = Int((Double(latencies.count - 1) * p).rounded())
        return latencies[max(0, min(latencies.count - 1, index))]
    }

    private func stat(_ label: String, _ ms: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.2f s", Double(ms) / 1000)).font(.title3.monospacedDigit())
        }
    }

    // MARK: エンジン内訳

    private var engineSection: some View {
        let counts = Dictionary(grouping: store.records.map(\.engine), by: { $0 })
            .mapValues(\.count)
        return VStack(alignment: .leading, spacing: 8) {
            Text("文字起こしエンジン").font(.headline)
            ForEach(counts.sorted(by: { $0.value > $1.value }), id: \.key) { key, value in
                HStack {
                    Text(key == "openai" ? "OpenAI（課金が発生した回数）" : "ローカル")
                    Spacer()
                    Text("\(value) 件").monospacedDigit()
                }
            }
        }
    }

    // MARK: 整形モデル内訳

    private var formatModelSection: some View {
        let counts = Dictionary(grouping: store.records.map(\.formatModel), by: { $0 })
            .mapValues(\.count)
        return VStack(alignment: .leading, spacing: 8) {
            Text("整形モデル").font(.headline)
            ForEach(counts.sorted(by: { $0.value > $1.value }), id: \.key) { key, value in
                HStack {
                    Text(key == "none" ? "整形なし" : key)
                    Spacer()
                    Text("\(value) 件").monospacedDigit()
                }
            }
        }
    }
}

/// レイテンシの分布を 500ms 刻みで出すだけの簡易ヒストグラム。
private struct Histogram: View {
    let values: [Int]

    private var buckets: [(label: String, count: Int)] {
        let edges = [500, 1000, 1500, 2000, 3000, 5000]
        var result: [(String, Int)] = []
        var previous = 0
        for edge in edges {
            let count = values.filter { $0 > previous && $0 <= edge }.count
            result.append(("〜\(String(format: "%.1f", Double(edge) / 1000))s", count))
            previous = edge
        }
        result.append(("5.0s 超", values.filter { $0 > previous }.count))
        return result
    }

    var body: some View {
        let maximum = max(1, buckets.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(buckets, id: \.label) { bucket in
                HStack(spacing: 8) {
                    Text(bucket.label)
                        .font(.caption.monospacedDigit())
                        .frame(width: 66, alignment: .trailing)
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(2, geometry.size.width * CGFloat(bucket.count) / CGFloat(maximum)))
                    }
                    .frame(height: 12)
                    Text("\(bucket.count)").font(.caption.monospacedDigit()).frame(width: 34, alignment: .leading)
                }
            }
        }
        .padding(.top, 4)
    }
}
