import Foundation

/// 値もキーも型を固定し、本文・入力先・音声を詳細ログへ渡さない。
public enum LatencyField:String,Sendable {
    case total, handoff, transform, queue, previousIssue, scheduledWait, timerOverrun, worker
    case issue, focus, eventPost, cooperativeYield, rangeEdit, sinkOther, deleted, inserted, preserved, completed, isFinal, recognitionSource
    case firstSpeechToResult, interimP50, interimP95, interimMax, interimCount
    case finalP50, finalP95, finalMax, finalCount
    case captureLagP50, captureLagP95, captureLagMax, captureLagCount
    case rawQueueP50, rawQueueP95, rawQueueMax, rawQueueCount
    case conversionP50, conversionP95, conversionMax, conversionCount
    case timelineValid, unmeasuredResults
    case frameLengthP50,frameLengthP95,frameLengthMax,frameLengthCount
    case sampleRateP50,sampleRateP95,sampleRateMax,sampleRateCount
    case callbackIntervalP50,callbackIntervalP95,callbackIntervalMax,callbackIntervalCount
    case localizedStage,localizedReason,localizedWaits,localizedIssued,localizedFallback
    case localizedAttempts,localizedCompletions,localizedUnavailable,localizedStops,correctionEvents,maximumRewrite
    case localizedEligible,localizedCostSkipped
    case localizedBelowThreshold,localizedInsufficientSuffix,localizedReplacementTooLong
}
public struct LatencyDiagnostic:Sendable,Encodable {
    public enum Stage:String,Sendable,Encodable {case speech,input,inputFailures,inputSummary}
    public struct Sample:Sendable,Encodable {
        public let sequence:Int
        public let values:[LatencyField:Double]
        public init(sequence:Int,values:[LatencyField:Double]) {
            self.sequence=min(max(0,sequence),1_000_000)
            self.values=values.filter {$0.value.isFinite && $0.value>=0}.mapValues {min($0,86_400_000)}
        }
        private enum CodingKeys:String,CodingKey {case sequence,values}
        public func encode(to encoder:any Encoder) throws {
            var container=encoder.container(keyedBy:CodingKeys.self)
            try container.encode(sequence,forKey:.sequence)
            try container.encode(Dictionary(uniqueKeysWithValues:values.map {($0.key.rawValue,$0.value)}),forKey:.values)
        }
    }
    public let session:UUID
    public let stage:Stage
    public let samples:[Sample]
    public init(session:UUID,stage:Stage,samples:[Sample]) {
        self.session=session;self.stage=stage;self.samples=Array(samples.prefix(stage == .speech || stage == .inputSummary ? 1:8))
    }
}

/// 長い収録でも数値の保持量を固定する。標本がない場合はゼロを作らない。
public struct LatencyWindow:Sendable {
    private var values:[Double]=[]
    private var cursor=0
    public init() {}
    public mutating func append(_ value:Double) {
        guard value.isFinite,value>=0 else {return}
        if values.count<512 {values.append(value)} else {values[cursor]=value;cursor=(cursor+1)%512}
    }
    public func store(in fields:inout [LatencyField:Double],keys:(LatencyField,LatencyField,LatencyField,LatencyField)) {
        guard !values.isEmpty else {return}
        let sorted=values.sorted(),count=sorted.count
        fields[keys.0]=sorted[(count+1)/2-1]
        fields[keys.1]=sorted[(count*95+99)/100-1]
        fields[keys.2]=sorted[count-1];fields[keys.3]=Double(count)
    }
}
