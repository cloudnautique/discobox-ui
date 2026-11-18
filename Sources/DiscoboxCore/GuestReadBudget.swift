import Foundation

/// App-wide admission for scheduled reads. Aliases reaching the same project
/// and pool draw from the same allowance. No inventory or credentials are shared.
@MainActor final class GuestReadBudget {
    private struct Pool {
        var active = 0
        var failures = 0
        var retryAfter: Date?
    }
    private struct Key: Hashable {
        let project, pool: String
    }
    private var pools: [Key: Pool] = [:]

    func begin(pool id: String, project: String, at now: Date) -> Bool {
        let key = Key(project: project, pool: id)
        var pool = pools[key] ?? Pool()
        if let deadline = pool.retryAfter {
            guard now >= deadline, pool.active == 0 else { return false }
        }
        guard pool.active < 2 else { return false }
        pool.active += 1
        pools[key] = pool
        return true
    }

    func finish(pool id: String, project: String, at now: Date, result: Result<Void, Error>?) {
        let key = Key(project: project, pool: id)
        guard var pool = pools[key] else { return }
        pool.active -= 1
        switch result {
        case .success:
            pool.failures = 0
            pool.retryAfter = nil
        case .failure(let error) where (error as? DiscoboxError)?.connectionRetryable == true || error is URLError:
            pool.failures = min(6, pool.failures + 1)
            if pool.failures >= 2 {
                let delay = min(300, 30 * pow(2, Double(pool.failures - 2)))
                pool.retryAfter = now.addingTimeInterval(delay)
            }
        default: break
        }
        if pool.active == 0 && pool.failures == 0 { pools.removeValue(forKey: key) }
        else { pools[key] = pool }
    }

    struct Deferred: Error {}
    func usageRead<T: Decodable & Sendable>(_ request: BridgeRequest, client: any DiscoboxClient, as type: T.Type) async throws -> T {
        guard let pool = request.poolID, let project = request.projectID, !Task.isCancelled else { throw CancellationError() }
        guard begin(pool: pool, project: project, at: Date()) else { throw Deferred() }
        var result: Result<Void, Error>?
        defer { finish(pool: pool, project: project, at: Date(), result: result) }
        do {
            let response = try await client.decode(request, as: type)
            try Task.checkCancellation()
            result = .success(())
            return response
        } catch {
            if !Task.isCancelled { result = .failure(error) }
            throw error
        }
    }
}
