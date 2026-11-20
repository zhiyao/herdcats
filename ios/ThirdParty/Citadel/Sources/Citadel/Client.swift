import NIO
import NIOConcurrencyHelpers
import Crypto
import Logging
import NIOSSH

extension SSHAlgorithms.Modification<NIOSSHTransportProtection.Type> {
    func apply(to configuration: inout [any NIOSSHTransportProtection.Type]) {
        switch self {
        case .add(let algorithms):
            configuration.append(contentsOf: algorithms)
            
            for algorithm: any NIOSSHTransportProtection.Type in algorithms {
                NIOSSHAlgorithms.register(transportProtectionScheme: algorithm)
            }
        case .replace(with: let algorithms):
            configuration = algorithms
            
            for algorithm in algorithms {
                NIOSSHAlgorithms.register(transportProtectionScheme: algorithm)
            }
        }
    }
}

extension SSHAlgorithms.Modification<NIOSSHKeyExchangeAlgorithmProtocol.Type> {
    func apply(to configuration: inout [any NIOSSHKeyExchangeAlgorithmProtocol.Type]) {
        switch self {
        case .add(let algorithms):
            configuration.append(contentsOf: algorithms)
            
            for algorithm in algorithms {
                NIOSSHAlgorithms.register(keyExchangeAlgorithm: algorithm)
            }
        case .replace(with: let algorithms):
            configuration = algorithms
            
            for algorithm in algorithms {
                NIOSSHAlgorithms.register(keyExchangeAlgorithm: algorithm)
            }
        }
    }
}

extension SSHAlgorithms.Modification<(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)>{
    func register() {
        switch self {
        case .add(let algorithms):
            for (publicKey, signature) in algorithms {
                NIOSSHAlgorithms.register(publicKey: publicKey, signature: signature)
            }
        case .replace(with: let algorithms):
            for (publicKey, signature) in algorithms {
                NIOSSHAlgorithms.register(publicKey: publicKey, signature: signature)
            }
        }
    }
}

public struct SSHAlgorithms: Sendable {
    /// Represents a modification to a list of items.
    ///
    /// - replace: Replaces the existing list of items with the given list of items.
    /// - add: Adds the given list of items to the list of items.
    public enum Modification<T: Sendable>: Sendable {
        case replace(with: [T])
        case add([T])
    }
    
    /// The enabled TransportProtectionSchemes.
    public var transportProtectionSchemes: Modification<NIOSSHTransportProtection.Type>?
    
    /// The enabled KeyExchangeAlgorithms
    public var keyExchangeAlgorithms: Modification<NIOSSHKeyExchangeAlgorithmProtocol.Type>?

    public var publicKeyAlgorihtms: Modification<(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)>?

    func apply(to clientConfiguration: inout SSHClientConfiguration) {
        transportProtectionSchemes?.apply(to: &clientConfiguration.transportProtectionSchemes)
        keyExchangeAlgorithms?.apply(to: &clientConfiguration.keyExchangeAlgorithms)
        publicKeyAlgorihtms?.register()
    }
    
    func apply(to serverConfiguration: inout SSHServerConfiguration) {
        transportProtectionSchemes?.apply(to: &serverConfiguration.transportProtectionSchemes)
        keyExchangeAlgorithms?.apply(to: &serverConfiguration.keyExchangeAlgorithms)
        publicKeyAlgorihtms?.register()
    }
    
    public init() {}

    public static let all: SSHAlgorithms = {
        var algorithms = SSHAlgorithms()

        algorithms.transportProtectionSchemes = .add([
            AES128CTR.self
        ])

        algorithms.keyExchangeAlgorithms = .add([
            DiffieHellmanGroup14Sha1.self,
            DiffieHellmanGroup14Sha256.self
        ])

        algorithms.publicKeyAlgorihtms = .add([
            (Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self),
        ])

        return algorithms
    }()
}

/// Represents an SSH connection.
public final class SSHClient {
    private(set) var session: SSHClientSession
    private enum OptionalTabAdmission {
        case pending, allowed, revoked
    }
    private let optionalTabList = NIOLockedValueBox((admission: OptionalTabAdmission.pending, query: OptionalTabListQuery?.none))
    private var userInitiatedClose = false
    let authenticationMethod: () -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    internal var connectionSettings = SSHConnectionPoolSettings()
    private let algorithms: SSHAlgorithms
    private let protocolOptions: Set<SSHProtocolOption>
    private var onDisconnect: (@Sendable () -> ())?
    public let logger = Logger(label: "nl.orlandos.citadel.client")
    public var isConnected: Bool {
        session.channel.isActive
    }
    
    /// The event loop that this SSH connection is running on.
    public var eventLoop: EventLoop {
        session.channel.eventLoop
    }
    
    init(
        session: SSHClientSession,
        authenticationMethod: @escaping @autoclosure () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption>
    ) {
        self.session = session
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.algorithms = algorithms
        self.protocolOptions = protocolOptions
        
        onNewSession(session)
    }
    
    public func onDisconnect(perform onDisconnect: @escaping @Sendable () -> ()) {
        self.onDisconnect = onDisconnect
    }

    /// Connects to an SSH server.
    /// - settings: The settings to use for the connection.
    /// - Returns: An SSH client.
    public static func connect(
        to settings: SSHClientSettings
    ) async throws -> SSHClient {
        let session = try await SSHClientSession.connect(settings: settings)
        
        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }

    /// Connects to an SSH server.
    /// - settings: The settings to use for the connection.
    /// - Returns: An SSH client.
    public static func connect(
        on channel: Channel,
        settings: SSHClientSettings
    ) async throws -> SSHClient {
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        try await SSHClientSession.addHandlers(
            on: channel,
            inboundChannelHandler: inboundChannelHandler,
            settings: settings
        ).get()
        
        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let handshakeHandler = try await channel.pipeline.handler(type: ClientHandshakeHandler.self).get()
        let session = try await handshakeHandler.authenticated.map {
            SSHClientSession(channel: channel, inboundChannelHandler: inboundChannelHandler, sshHandler: sshHandler)
        }.get()

        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }

    public func jump(to settings: SSHClientSettings) async throws -> SSHClient {
        let originatorAddress = try SocketAddress(ipAddress: "fe80::1", port: 22)
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        let channel = try await self.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(
                targetHost: settings.host,
                targetPort: settings.port,
                originatorAddress: originatorAddress
            )
        ) { channel in
            SSHClientSession.addHandlers(
                on: channel,
                inboundChannelHandler: inboundChannelHandler,
                settings: settings
            )
        }
        
        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let handshakeHandler = try await channel.pipeline.handler(type: ClientHandshakeHandler.self).get()
        let session = try await handshakeHandler.authenticated.map {
            SSHClientSession(channel: channel, inboundChannelHandler: inboundChannelHandler, sshHandler: sshHandler)
        }.get()

        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }
    
    /// Connects to an SSH server.
    /// - Parameters:
    ///  - channel: The channel to use for the connection.
    /// - authenticationMethod: The authentication method to use. See `SSHAuthenticationMethod` for more information.
    /// - hostKeyValidator: The host key validator to use. See `SSHHostKeyValidator` for more information.
    /// - algorithms: The algorithms to use. See `SSHAlgorithms` for more information.
    /// - protocolOptions: The protocol options to use. See `SSHProtocolOption` for more information.
    /// - Returns: An SSH client.
    public static func connect(
        on channel: Channel,
        authenticationMethod: @escaping @autoclosure () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = []
    ) async throws -> SSHClient {
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        try await SSHClientSession.addHandlers(
            on: channel,
            authenticationMethod: authenticationMethod(),
            inboundChannelHandler: inboundChannelHandler,
            hostKeyValidator: hostKeyValidator,
            protocolOptions: protocolOptions
        ).get()
        
        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let session = SSHClientSession(channel: channel, inboundChannelHandler: inboundChannelHandler, sshHandler: sshHandler)
        
        return SSHClient(
            session: session,
            authenticationMethod: authenticationMethod(),
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions
        )
    }
    
    /// Connects to an SSH server.
    /// - Parameters:
    /// - host: The host to connect to.
    /// - port: The port to connect to. Defaults to 22.
    /// - authenticationMethod: The authentication method to use. See `SSHAuthenticationMethod` for more information.
    /// - hostKeyValidator: The host key validator to use. See `SSHHostKeyValidator` for more information.
    /// - reconnect: The reconnect mode to use. See `SSHReconnectMode` for more information.
    /// - algorithms: The algorithms to use. See `SSHAlgorithms` for more information.
    /// - protocolOptions: The protocol options to use. See `SSHProtocolOption` for more information.
    /// - group: The event loop group to use. Defaults to a single-threaded event loop group.
    /// - channelHandlers: Pass in an array of channel prehandlers that execute first. Default empty array
    /// - connectTimeout: Pass in the time before the connection times out. Default 30 seconds.
    /// - Returns: An SSH client.
    public static func connect(
        host: String,
        port: Int = 22,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        reconnect: SSHReconnectMode,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = [],
        group: MultiThreadedEventLoopGroup = .singleton,
        channelHandlers: [ChannelHandler] = [],
        connectTimeout:TimeAmount = .seconds(30)
    ) async throws -> SSHClient {
        let session = try await SSHClientSession.connect(
            host: host,
            port: port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions,
            group: group,
            channelHandlers: channelHandlers,
            connectTimeout: connectTimeout
        )
        
        let client = SSHClient(
            session: session,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions
        )
        
        switch reconnect.mode {
        case .always:
            client.connectionSettings.reconnect = .always(to: host, port: port)
        case .once:
            client.connectionSettings.reconnect = .once(to: host, port: port)
        case .never:
            client.connectionSettings.reconnect = .never
        }
        
        return client
    }
    
    private func onNewSession(_ session: SSHClientSession) {
        session.channel.closeFuture.whenComplete { [weak self] _ in
            self?.invalidateOptionalTabList()
            self?.onClose()
        }
    }
    
    private func onClose() {
        Task {
            self.onDisconnect?()
            
            switch connectionSettings.reconnect.mode {
            case .never:
                return
            case .once(let host, let port):
                _ = try? await self.recreateSession(host: host, port: port)
            case .always(let host, let port):
                func tryAgain() async throws {
                    do {
                        try await self.recreateSession(host: host, port: port)
                    } catch {
                        return try await tryAgain()
                    }
                }
                
                _ = try? await tryAgain()
            }
        }
    }
    
    private func recreateSession(host: String, port: Int) async throws {
        if userInitiatedClose {
            return
        }
        
        self.session = try await SSHClientSession.connect(
            host: host,
            port: port,
            authenticationMethod: self.authenticationMethod(),
            hostKeyValidator: self.hostKeyValidator,
            protocolOptions: protocolOptions,
            group: session.channel.eventLoop
        )
        
        onNewSession(session)
    }
    
    /// Runs optional tab metadata on its own socket. Closing this socket also
    /// releases a session-channel open that the server never acknowledges.
    public func executeOptionalTabList(
        _ command: String, deadline: ContinuousClock.Instant
    ) async throws -> ByteBuffer {
        try Task.checkCancellation()
        let query = OptionalTabListQuery(owner: session.channel, deadline: deadline)
        guard optionalTabList.withLockedValue({ state in
            guard state.admission == .allowed, state.query == nil else { return false }
            state.query = query
            return true
        }) else { throw CitadelError.channelCreationFailed }
        defer { optionalTabList.withLockedValue { $0.query = nil } }

        guard let endpoint = query.owner.remoteAddress,
              let host = endpoint.ipAddress, let port = endpoint.port,
              let auth = authenticationMethod().freshBuiltInMethod() else {
            throw CitadelError.channelCreationFailed
        }
        var settings = SSHClientSettings(
            host: host, port: port, authenticationMethod: { auth }, hostKeyValidator: hostKeyValidator
        )
        settings.algorithms = algorithms
        settings.protocolOptions = protocolOptions
        let querySettings = settings
        let inbound = SSHClientInboundChannelHandler()
        let expiry = Task {
            try await ContinuousClock().sleep(until: deadline)
            query.cancel()
        }
        defer { expiry.cancel() }

        do {
            return try await withTaskCancellationHandler {
                let remaining = ContinuousClock.now.duration(to: deadline)
                let (seconds, attoseconds) = remaining.components
                let timeout = TimeAmount.nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
                try query.whileActive {}
                let socket = try await ClientBootstrap(group: query.owner.eventLoop)
                    .channelInitializer { channel in
                        do {
                            try query.install(channel)
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                        return SSHClientSession.addHandlers(
                            on: channel, inboundChannelHandler: inbound, settings: querySettings
                        )
                    }
                    .connectTimeout(timeout)
                    .connect(to: endpoint).get()
                let result: Result<ByteBuffer, Error>
                do {
                    try query.whileActive {}
                    try await socket.pipeline.handler(type: ClientHandshakeHandler.self)
                        .flatMap { $0.authenticated }.get()
                    let session = try await socket.pipeline.handler(type: NIOSSHHandler.self).map { handler in
                        SSHClientSession(channel: socket, inboundChannelHandler: inbound, sshHandler: handler)
                    }.get()
                    result = .success(try await session.readOptionalTabList(command, query: query))
                } catch {
                    result = .failure(error)
                }
                socket.close(promise: nil)
                _ = try? await socket.closeFuture.get()
                try Task.checkCancellation()
                try query.whileActive {}
                return try result.get()
            } onCancel: {
                query.cancel()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    public func allowOptionalTabList() -> Bool {
        optionalTabList.withLockedValue { state in
            guard state.admission != .revoked, isConnected else { return false }
            state.admission = .allowed
            return true
        }
    }

    public func invalidateOptionalTabList() {
        let socket = optionalTabList.withLockedValue { state in
            let socket = state.query?.revoke()
            state.admission = .revoked
            return socket
        }
        socket?.close(promise: nil)
    }

    public func close() async throws {
        invalidateOptionalTabList()
        self.userInitiatedClose = true
        try await self.session.channel.close()
    }
}

final class OptionalTabListQuery: Sendable {
    let owner: Channel
    private let deadline: ContinuousClock.Instant
    private let state = NIOLockedValueBox((cancelled: false, socket: Channel?.none))

    init(owner: Channel, deadline: ContinuousClock.Instant) {
        self.owner = owner
        self.deadline = deadline
    }

    private func requireActive(cancelled: Bool) throws {
        guard !cancelled, owner.isActive, ContinuousClock.now < deadline else {
            throw CitadelError.channelCreationFailed
        }
    }

    func install(_ socket: Channel) throws {
        try state.withLockedValue { state in
            try requireActive(cancelled: state.cancelled)
            state.socket = socket
        }
    }

    func whileActive<T>(_ operation: () -> T) throws -> T {
        try state.withLockedValue { state in
            try requireActive(cancelled: state.cancelled)
            return operation()
        }
    }

    fileprivate func revoke() -> Channel? {
        state.withLockedValue { state in
            state.cancelled = true
            let socket = state.socket
            state.socket = nil
            return socket
        }
    }

    func cancel() {
        revoke()?.close(promise: nil)
    }
}
