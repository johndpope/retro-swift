import CRetro
import Foundation

public class Movie {
  private var handle: UnsafeMutablePointer<CMovie>?

  public init(at url: URL, recording: Bool, numPlayers: UInt32) {
    self.handle = movieCreate(url.path, recording, numPlayers)
  }

  deinit {
    movieDelete(handle)
  }

  public var state: Data {
    get {
      let cBytesPointer = movieGetState(handle)!
      defer { cBytesPointer.deallocate() }
      let cBytes = cBytesPointer.pointee
      return Data(bytes: cBytes.bytes, count: cBytes.numBytes)
    }
    set (newValue) {
      let bytes = [UInt8](newValue)
      bytes.withUnsafeBufferPointer {
        var cBytesStruct = CBytes(bytes: $0.baseAddress, numBytes: bytes.count)
        movieSetState(handle, &cBytesStruct)
      }
    }
  }

  public func configure<ActionsType: Retro.ActionsType>(for environment: Environment<ActionsType>) {
    movieConfigure(handle, environment.game().name, environment.emulator.handle)
  }

  public func game() -> String {
    let cString = movieGetGameName(handle)!
    defer { cString.deallocate() }
    return String(cString: cString)
  }

  @discardableResult
  public func step() -> Bool {
    return movieStep(handle)
  }

  public func close() {
    movieClose(handle)
  }

  public func numPlayers() -> UInt32 {
    return moviePlayers(handle)
  }

  public subscript(key: Int, forPlayer player: UInt32) -> Bool {
    get { return movieGetKey(handle, Int32(key), player) }
    set { movieSetKey(handle, Int32(key), newValue, player) }
  }
}
