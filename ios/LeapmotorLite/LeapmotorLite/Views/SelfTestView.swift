//
//  SelfTestView.swift
//  LeapmotorLite
//
//  算法自检页：用真实抓包向量验证 HMAC / XOR3 / AES / MD5 实现
//
import SwiftUI

struct SelfTestView: View {
    @State private var results: [LMSelfTest.Result] = []

    var body: some View {
        List {
            Section {
                let passed = results.filter(\.passed).count
                HStack {
                    Image(systemName: passed == results.count && !results.isEmpty
                          ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(passed == results.count && !results.isEmpty ? .green : .red)
                    Text("\(passed) / \(results.count) 通过")
                        .font(.headline)
                }
            }

            Section("结果") {
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.passed ? .green : .red)
                            Text(r.name).font(.footnote.weight(.medium))
                        }
                        Text(r.detail)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                }
            }

            Section {
                Text("""
                这些向量来自 evidence/har_appgw.har 的真实抓包：
                · signKey = 7C2C1588…AC566
                · oppwd("4211") = uHTigfMDS5zIuZX4Gq4NVQ==
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
