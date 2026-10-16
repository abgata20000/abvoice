import Foundation

/// 16bit PCM の生データに RIFF/WAVE ヘッダを付けるだけの小物。
/// 変換を挟まずに文字起こしへ渡せるよう、WAV（16kHz / mono）にする。
enum WavEncoder {
    static func wav(pcm16: Data, sampleRate: Int, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(le32(UInt32(36 + pcm16.count)))
        header.append("WAVE".data(using: .ascii)!)

        header.append("fmt ".data(using: .ascii)!)
        header.append(le32(16))              // PCM の fmt チャンクは 16 バイト
        header.append(le16(1))               // フォーマット 1 = リニア PCM
        header.append(le16(UInt16(channels)))
        header.append(le32(UInt32(sampleRate)))
        header.append(le32(UInt32(byteRate)))
        header.append(le16(UInt16(blockAlign)))
        header.append(le16(UInt16(bitsPerSample)))

        header.append("data".data(using: .ascii)!)
        header.append(le32(UInt32(pcm16.count)))

        return header + pcm16
    }

    private static func le16(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 2)
    }

    private static func le32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }
}
