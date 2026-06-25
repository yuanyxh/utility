import Foundation

public enum TaskExecutor {
  public struct Result {
    let success: Bool
    let output: String
    let error: String
  }

  /// 同步执行（调用方负责放到后台线程）
  public static func execute(_ config: TaskExecConfig) -> Result {
    let pc = config.toProcess()

    do {
      try pc.task.run()
      pc.task.waitUntilExit()

      let outData = pc.outputPipe.fileHandleForReading.readDataToEndOfFile()
      let errData = pc.errorPipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: outData, encoding: .utf8) ?? ""
      let error = String(data: errData, encoding: .utf8) ?? ""

      return Result(success: pc.task.terminationStatus == 0, output: output, error: error)
    } catch {
      return Result(success: false, output: "", error: error.localizedDescription)
    }
  }

  /// 流式执行——stdout/stderr 实时回调到主线程
  /// - Returns: Process 对象，调用方可调用 `.terminate()` 取消执行并释放资源
  @discardableResult
  public static func execute(
    _ config: TaskExecConfig,
    onOutput: ((String) -> Void)?,
    onComplete: @escaping (Result) -> Void
  ) -> Process {
    let pc = config.toProcess()
    var accumulatedOutput = ""
    var accumulatedError = ""
    let bufferLock = NSLock()

    pc.outputPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      if let str = String(data: data, encoding: .utf8), !str.isEmpty {
        bufferLock.lock()
        accumulatedOutput += str
        bufferLock.unlock()
        if let cb = onOutput {
          DispatchQueue.main.async { cb(str) }
        }
      }
    }

    pc.errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      if let str = String(data: data, encoding: .utf8), !str.isEmpty {
        bufferLock.lock()
        accumulatedError += str
        bufferLock.unlock()
        if let cb = onOutput {
          DispatchQueue.main.async { cb(str) }
        }
      }
    }

    DispatchQueue.global(qos: .utility).async {
      do {
        try pc.task.run()
        pc.task.waitUntilExit()

        // 停止 handler 后再读残留数据，避免竞态
        pc.outputPipe.fileHandleForReading.readabilityHandler = nil
        pc.errorPipe.fileHandleForReading.readabilityHandler = nil

        let outRemaining = String(data: pc.outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errRemaining = String(data: pc.errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        bufferLock.lock()
        accumulatedOutput += outRemaining
        accumulatedError += errRemaining
        let finalOutput = accumulatedOutput
        let finalError = accumulatedError
        bufferLock.unlock()

        if !outRemaining.isEmpty, let cb = onOutput {
          DispatchQueue.main.async { cb(outRemaining) }
        }
        if !errRemaining.isEmpty, let cb = onOutput {
          DispatchQueue.main.async { cb(errRemaining) }
        }

        DispatchQueue.main.async {
          onComplete(Result(success: pc.task.terminationStatus == 0, output: finalOutput, error: finalError))
        }
      } catch {
        pc.outputPipe.fileHandleForReading.readabilityHandler = nil
        pc.errorPipe.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async {
          onComplete(Result(success: false, output: "", error: error.localizedDescription))
        }
      }
    }

    return pc.task
  }
}
