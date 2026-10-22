/// アプリが所有するストリームとエンジンの数値だけを公開する。
/// キューはyield時点の最大件数で、SDK内部やOS全体のマイク占有は含まない。
public struct SpeechResourceSnapshot: Equatable, Sendable {
    public let rawAudioPeak:Int
    public let analyzerInputPeak:Int
    public let recognitionPeak:Int
    public let audioStreams:Int
    public let resultStreams:Int
    public let captureRunning:Bool
    public init(rawAudioPeak:Int=0,analyzerInputPeak:Int=0,recognitionPeak:Int=0,audioStreams:Int=0,resultStreams:Int=0,captureRunning:Bool=false) {
        self.rawAudioPeak=rawAudioPeak;self.analyzerInputPeak=analyzerInputPeak;self.recognitionPeak=recognitionPeak
        self.audioStreams=audioStreams;self.resultStreams=resultStreams;self.captureRunning=captureRunning
    }
}
