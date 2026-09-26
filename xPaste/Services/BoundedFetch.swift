import Foundation

/// A GET that decides, once the headers are in, how much of the body it wants — and stops there.
///
/// `URLSession.data(for:)` returns only after it has buffered the whole body, which is where a
/// copied link to a download went: the preview read every byte of `EVKeyMac.zip` into memory to
/// look for an `og:title`, found none, cached nothing because there was nothing to cache, and
/// did it again every time the card came back on screen. A link to a 5 GB disk image would have
/// read 5 GB. The request's `timeoutInterval` never stopped it, because it measures silence
/// between packets rather than how long the whole transfer takes.
///
/// Here the caller sees the response first and answers with a `Plan`. A download is answered
/// from its headers alone and the transfer is cancelled before the body starts; a page is read
/// until its `</head>`; a picture is read until it is whole or proves too big to keep.
final class BoundedFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Plan {
        /// The headers are the whole answer. The body is never read.
        case headersOnly
        /// Read at most `cap` bytes, stopping as soon as the body contains one of `stopAfter`
        /// (the needle is kept). A body that runs past the cap is cut to it, or rejected outright.
        case body(cap: Int, stopAfter: [Data], overflow: Overflow)
    }

    enum Overflow { case truncate, reject }

    struct Result {
        let response: HTTPURLResponse
        let data: Data
    }

    static let shared = BoundedFetch()

    private var session: URLSession!
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]

    /// `configuration` is there for the tests, which route requests through a stub protocol.
    init(configuration: URLSessionConfiguration = .default) {
        super.init()
        // A nil queue gives the session a serial one of its own, so the callbacks for one task
        // never overlap and a `Job` needs no locking of its own — only the table of them does.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Nil for anything but a 200, for a transport failure, for a body rejected by its plan, and
    /// for a fetch whose Swift task was cancelled — the card that asked has gone off screen.
    func fetch(_ request: URLRequest,
               plan: @escaping (HTTPURLResponse) -> Plan) async -> Result? {
        let handle = TaskHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                jobs[task.taskIdentifier] = Job(plan: plan, continuation: continuation)
                lock.unlock()
                handle.set(task)
                task.resume()
            }
        } onCancel: {
            handle.cancel()
        }
    }

    // MARK: - Delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let job = job(for: dataTask) else { return completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            finish(dataTask, with: nil)
            return completionHandler(.cancel)
        }
        job.response = http
        job.plan = job.decide(http)
        switch job.plan {
        case .headersOnly:
            finish(dataTask, with: Result(response: http, data: Data()))
            completionHandler(.cancel)
        case let .body(cap, _, overflow):
            // Refused on what the server declared, before a byte of it arrives. `data.count` in
            // the data callback is still what decides for a server that declares nothing (-1).
            if overflow == .reject, http.expectedContentLength > Int64(cap) {
                finish(dataTask, with: nil)
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = job(for: dataTask), let response = job.response,
              case let .body(cap, needles, overflow) = job.plan
        else { return }

        let before = job.data.count
        job.data.append(data)

        // Only the new bytes and the tail a needle could straddle into them are searched, so a
        // page arriving in many small chunks is not rescanned from the top every time.
        let longest = needles.map(\.count).max() ?? 0
        let from = job.data.startIndex + max(0, before - longest + 1)
        let ends = needles.compactMap { job.data.range(of: $0, in: from..<job.data.endIndex)?.upperBound }
        if let end = ends.min(), end - job.data.startIndex <= cap {
            finish(dataTask, with: Result(response: response, data: job.data.prefix(upTo: end)))
            return dataTask.cancel()
        }

        if job.data.count > cap {
            finish(dataTask, with: overflow == .truncate
                   ? Result(response: response, data: job.data.prefix(cap)) : nil)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = job(for: task) else { return }
        guard error == nil, let response = job.response else { return finish(task, with: nil) }
        finish(task, with: Result(response: response, data: job.data))
    }

    // MARK: - Bookkeeping

    private final class Job {
        let decide: (HTTPURLResponse) -> Plan
        let continuation: CheckedContinuation<Result?, Never>
        var response: HTTPURLResponse?
        var plan: Plan = .headersOnly
        var data = Data()

        init(plan: @escaping (HTTPURLResponse) -> Plan,
             continuation: CheckedContinuation<Result?, Never>) {
            self.decide = plan
            self.continuation = continuation
        }
    }

    private func job(for task: URLSessionTask) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs[task.taskIdentifier]
    }

    /// Resumes the caller exactly once: the job leaves the table here, so the completion callback
    /// that follows a cancel finds nothing and does nothing.
    private func finish(_ task: URLSessionTask, with result: Result?) {
        lock.lock()
        let job = jobs.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        job?.continuation.resume(returning: result)
    }

    /// The task a cancellation has to reach, which may not exist yet when the cancellation lands.
    private final class TaskHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func set(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let cancelNow = cancelled
            lock.unlock()
            if cancelNow { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }
}
