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
}
