/// 録音を伴わない準備結果を一つだけ所有する。開始側は準備中の完了を待たない。
@MainActor public final class SpeechPreparationController<Key:Equatable,Resource> {
    private let release:@MainActor (Resource) async -> Void
    private var ready:(Key,Resource)?
    private var requested:Key?
    private var generation=0
    private var worker:Task<Void,Never>?
    public init(release:@escaping @MainActor (Resource) async -> Void) {self.release=release}
    public func request(key:Key,prepare:@escaping @MainActor () async throws -> Resource) {
        guard requested != key else {return}
        generation += 1
        let revision=generation,previous=worker,stale=ready?.1
        previous?.cancel();ready=nil;requested=key
        worker=Task { [self] in
            await previous?.value
            if let stale {await release(stale)}
            guard !Task.isCancelled,generation==revision else {return}
            do {
                let resource=try await prepare()
                guard !Task.isCancelled,generation==revision,requested==key else {await release(resource);return}
                ready=(key,resource)
            } catch {
                if generation==revision {requested=nil}
            }
        }
    }
    public func take(key:Key)->Resource? {
        let resource=ready?.0==key ? ready?.1:nil
        if resource != nil {ready=nil}
        invalidate()
        return resource
    }
    public func invalidate() {
        generation += 1
        let previous=worker,stale=ready?.1
        previous?.cancel();ready=nil;requested=nil
        worker=Task { [release] in
            await previous?.value
            if let stale {await release(stale)}
        }
    }
    public func close() async {invalidate();await worker?.value}
    public func waitForPreparation() async {await worker?.value}
}
