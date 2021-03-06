import CRetro
import Foundation
import Gzip
import TensorFlow

public struct Environment<ActionsType: Retro.ActionsType> {
  public let emulator: Emulator
  public let actionsType: ActionsType
  public let actionSpace: ActionsType.Space
  public let observationsType: ObservationsType
  public let observationSpace: Box<UInt8>
  public let startingState: String?
  public let randomSeed: UInt64

  @usableFromInline internal var rng: PhiloxRandomNumberGenerator

  public private(set) var movie: Movie?
  public private(set) var movieID: Int
  public private(set) var movieURL: URL?

  public init(
    using emulator: Emulator,
    actionsType: ActionsType,
    observationsType: ObservationsType = .screen,
    startingState: StartingState = .provided,
    movieURL: URL? = nil,
    randomSeed: UInt64? = nil
   ) throws {
    self.emulator = emulator
    self.actionsType = actionsType
    self.actionSpace = actionsType.space(for: emulator)
    self.observationsType = observationsType
    switch observationsType {
    case .screen: self.observationSpace = Box(low: 0, high: 255, shape: emulator.screen()!.shape)
    case .memory: self.observationSpace = Box(low: 0, high: 255, shape: emulator.memory()!.shape)
    }
    self.randomSeed = hashSeed(createSeed(using: randomSeed))
    self.rng = PhiloxRandomNumberGenerator(seed: self.randomSeed)
    self.movie = nil
    self.movieID = 0
    self.movieURL = movieURL

    switch startingState {
    case .none:
      self.startingState = nil
    case .provided:
      let gameMetadataJson = try? String(contentsOf: self.emulator.game.metadataFile!)
      let gameMetadata = try? Game.Metadata(fromJson: gameMetadataJson!)
      if let metadata = gameMetadata {
        let defaultState = metadata.defaultState
        let defaultPlayerState = metadata.defaultPlayerState
        if defaultPlayerState != nil && emulator.numPlayers <= defaultPlayerState!.count {
          self.startingState = defaultPlayerState![Int(emulator.numPlayers) - 1]
        } else if defaultState != nil {
          self.startingState = defaultState!
        } else {
          self.startingState = nil
        }
      } else {
        self.startingState = nil
      }
    case .custom(let state):
      self.startingState = state
    }

    if let state = self.startingState {
      try self.emulator.loadStartingState(
        from: game().dataDir.appendingPathComponent("\(state).state"))
    }

    reset()
  }

  @inlinable
  public mutating func seed(using seed: UInt64? = nil) -> UInt64 {
    let strongSeed = hashSeed(createSeed(using: seed))
    self.rng = PhiloxRandomNumberGenerator(seed: strongSeed)
    return strongSeed
  }

  @discardableResult
  public func step(taking action: ShapedArray<ActionsType.Space.Scalar>) -> StepResult {
    for p in 0..<numPlayers() {
      let numButtons = emulator.buttons().count
      let encodedAction = actionsType.encodeAction(action, for: p, in: emulator)
      var buttonMask = [UInt8](repeating: 0, count: numButtons)
      for i in 0..<numButtons {
        buttonMask[i] = UInt8((encodedAction >> i) & 1)
        movie?[i, forPlayer: p] = buttonMask[i] > 0
      }
      emulator.setButtonMask(for: p, to: buttonMask)
    }

    movie?.step()
    emulator.step()

    let observation: ShapedArray<UInt8>? = {
      switch observationsType {
      case .screen: return emulator.screen()
      case .memory: return emulator.memory()
      }
    }()
    let reward = (0..<numPlayers()).map { emulator.reward(for: $0) }
    let finished = emulator.finished()

    // TODO: What about the 'info' dict?
    return StepResult(observation: observation, reward: reward, finished: finished)
  }

  public func render<R: Renderer>(
    using renderer: inout R
  ) throws where R.Data == ShapedArray<UInt8> {
    try renderer.render(emulator.screen()!)
  }

  public mutating func reset() {
    emulator.reset()

    // Reset the recording.
    if let url = movieURL {
      let state = String(startingState?.split(separator: ".")[0] ?? "none")
      let movieFilename = "\(game())-\(state)-\(String(format: "%06d", movieID)).bk2"
      startRecording(at: url.appendingPathComponent(movieFilename))
      movieID += 1
    }

    movie?.step()
  }

  public mutating func startRecording(at url: URL) {
    movie = Movie(at: url, recording: true, numPlayers: emulator.numPlayers)
    movie!.configure(for: self)
    if let state = emulator.startingStateData {
      movie!.state = state
    }
  }

  public mutating func enableRecording(at url: URL) {
    movieURL = url
  }

  public mutating func disableRecording() {
    movieID = 0
    movieURL = nil
    if let m = movie {
      m.close()
      movie = nil
    }
  }

  @inlinable
  public func game() -> Game {
    return emulator.game
  }

  @inlinable
  public func numPlayers() -> UInt32 {
    return emulator.numPlayers
  }
}

public extension Environment {
  /// Represents the initial state of the emulator.
  enum StartingState {
    /// Start the game at the power on screen of the emulator.
    case none
    
    /// Start the game at the default save state from `metadata.json`.
    case provided

    /// Start the game from the save state file specified.
    /// The provided string is the name of the `.state` file to use.
    case custom(String)
  }

  struct StepResult {
    let observation: ShapedArray<UInt8>?
    let reward: [Float]
    let finished: Bool
  }
}

public extension Environment {
  mutating func sampleAction() -> ShapedArray<ActionsType.Space.Scalar> {
    return actionSpace.sample(generator: &rng)
  }
}

/// Represents different settings for the observation space of the environment.
public enum ObservationsType: Int {
  /// Use RGB image observations.
  case screen

  /// Use RAM observations where you can see the memory of the game instead of the screen.
  case memory
}

/// Represents different types of action space for the environment.
public protocol ActionsType {
  associatedtype Space: Retro.Space

  func space(for emulator: Emulator) -> Space

  func encodeAction(
    _ action: ShapedArray<Space.Scalar>,
    for player: UInt32,
    in emulator: Emulator
  ) -> UInt16
}

/// Multi-binary action space with no filtered actions.
public struct FullActions: ActionsType {
  public typealias Space = MultiBinary

  public func space(for emulator: Emulator) -> MultiBinary {
    return MultiBinary(withSize: emulator.buttons().count * Int(emulator.numPlayers))
  }

  public func encodeAction(
    _ action: ShapedArray<Space.Scalar>,
    for player: UInt32,
    in emulator: Emulator
  ) -> UInt16 {
    let startIndex = emulator.buttons().count * Int(player)
    let endIndex = emulator.buttons().count * Int(player + 1)
    let playerAction = action[startIndex..<endIndex].scalars
    var encodedAction = UInt16(0)
    for i in 0..<playerAction.count {
      encodedAction |= UInt16(playerAction[i]) << i
    }
    return encodedAction
  }
}

/// Multi-binary action space with invalid or not allowed actions filtered out.
public struct FilteredActions: ActionsType {
  public typealias Space = MultiBinary

  public func space(for emulator: Emulator) -> MultiBinary {
    return MultiBinary(withSize: emulator.buttons().count * Int(emulator.numPlayers))
  }

  public func encodeAction(
    _ action: ShapedArray<Space.Scalar>,
    for player: UInt32,
    in emulator: Emulator
  ) -> UInt16 {
    let startIndex = emulator.buttons().count * Int(player)
    let endIndex = emulator.buttons().count * Int(player + 1)
    let playerAction = action[startIndex..<endIndex].scalars
    var encodedAction = UInt16(0)
    for i in 0..<playerAction.count {
      encodedAction |= UInt16(playerAction[i]) << i
    }
    return gameDataFilterAction(emulator.gameData.handle, encodedAction)
  }
}

/// Discrete action space for filtered actions.
public struct DiscreteActions: ActionsType {
  public typealias Space = Discrete

  public func space(for emulator: Emulator) -> Discrete {
    let numCombos = emulator.buttonCombos().map { Int32($0.count) } .reduce(1, *)
    return Discrete(withSize: Int32(pow(Float(numCombos), Float(emulator.numPlayers))))
  }

  public func encodeAction(
    _ action: ShapedArray<Space.Scalar>,
    for player: UInt32,
    in emulator: Emulator
  ) -> UInt16 {
    var playerAction = UInt16(action.scalar!)
    var encodedAction = UInt16(0)
    var current = 0
    for combo in emulator.buttonCombos() {
      current = Int(playerAction) % combo.count
      playerAction /= UInt16(combo.count)
      encodedAction |= UInt16(combo[current])
    }
    return encodedAction
  }
}

/// Multi-discete action space for filtered actions.
public struct MultiDiscreteActions: ActionsType {
  public typealias Space = MultiDiscrete

  public func space(for emulator: Emulator) -> MultiDiscrete {
    return MultiDiscrete(withSizes: emulator.buttonCombos().map {
      Int32($0.count) * Int32(emulator.numPlayers)
    })
  }

  public func encodeAction(
    _ action: ShapedArray<Space.Scalar>,
    for player: UInt32,
    in emulator: Emulator
  ) -> UInt16 {
    let startIndex = emulator.buttons().count * Int(player)
    let endIndex = emulator.buttons().count * Int(player + 1)
    let playerAction = action[startIndex..<endIndex].scalars
    var encodedAction = UInt16(0)
    for i in 0..<playerAction.count {
      let combo = emulator.buttonCombos()[i]
      encodedAction |= UInt16(combo[Int(playerAction[i])])
    }
    return encodedAction
  }
}
