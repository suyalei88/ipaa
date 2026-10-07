//
//  SelfTestView.swift
//  LeapmotorLite
//
//  算法自检页：用真实抓包向量验证 HMAC / XOR3 / AES / MD5 实现，
//  外加坐标换算（WGS-84 ↔ GCJ-02）的参考向量校验。
//
import SwiftUI
import Foundation

struct SelfTestView: View {
    @State private var results: [LMSelfTest.Result] = []

    private var passedCount: Int { results.filter(\.passed).count }
    private var allPassed: Bool { !results.isEmpty && passedCount == results.count }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: allPassed ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(allPassed ? Color.lmGood : Color.lmBad)
                    Text("\(passedCount) / \(results.count) 通过")
                        .font(.title3.weight(.bold))
                    Text(allPassed
                         ? "签名与加密实现与官方 App 逐字节一致"
                         : "有不一致项，车控一定不通，先修这个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section("结果") {
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.passed ? Color.lmGood : Color.lmBad)
                            Text(r.name)
                                .font(.footnote.weight(.medium))
                        }
                        Text(r.detail)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Text("""
                这些向量来自 evidence/har_appgw.har 的真实抓包：
                · signKey = 7C2C1588…AC566
                · oppwd("4211") = uHTigfMDS5zIuZX4Gq4NVQ==
                坐标那几条的参考值由 client/test_coord_vectors.py 独立算出。
                全部通过才说明签名与加密实现与官方 App 逐字节一致。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("算法自检")
        .onAppear { results = LMSelfTest.run() }
    }
}
