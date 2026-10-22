/// 実際に届くサイズはOSが決める。値は比較用の要求フレーム数。
public enum SpeechBufferSize:Int,Codable,CaseIterable,Sendable {
    case standard=4096,medium=2048,small=1024,smallest=512
}
