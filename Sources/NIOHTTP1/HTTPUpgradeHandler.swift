//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

/// Errors that may be raised by the `HTTPProtocolUpgrader`.
public enum HTTPUpgradeErrors: Error {
    case invalidHTTPOrdering
}

/// User events that may be fired by the `HTTPProtocolUpgrader`.
public enum HTTPUpgradeEvents {
    /// Fired when HTTP upgrade has completed and the
    /// `HTTPProtocolUpgrader` is about to remove itself from the
    /// `ChannelPipeline`.
    case upgradeComplete(toProtocol: String, upgradeRequest: HTTPRequestHead)
}


/// An object that implements `ProtocolUpgrader` knows how to handle HTTP upgrade to
/// a protocol.
public protocol HTTPProtocolUpgrader {
    /// The protocol this upgrader knows how to support.
    var supportedProtocol: String { get }

    /// All the header fields the protocol needs in the request to successfully upgrade. These header fields
    /// will be provided to the handler when it is asked to handle the upgrade. They will also be validated
    ///  against the inbound request's Connection header field.
    var requiredUpgradeHeaders: [String] { get }

    /// Builds the upgrade response headers. Should return any headers that need to be supplied to the client
    /// in the 101 Switching Protocols response. If upgrade cannot proceed for any reason, this function should
    /// throw.
    func buildUpgradeResponse(upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) throws -> HTTPHeaders

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel pipeline
    /// to add whatever channel handlers are required. Until the returned `EventLoopFuture` succeeds, all received
    /// data will be buffered.
    func upgrade(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void>
}

/// A server-side channel handler that receives HTTP requests and optionally performs a HTTP-upgrade.
/// Removes itself from the channel pipeline after the first inbound request on the connection, regardless of
/// whether the upgrade succeeded or not.
///
/// This handler behaves a bit differently from its Netty counterpart because it does not allow upgrade
/// on any request but the first on a connection. This is primarily to handle clients that pipeline: it's
/// sufficiently difficult to ensure that the upgrade happens at a safe time while dealing with pipelined
/// requests that we choose to punt on it entirely and not allow it. As it happens this is mostly fine:
/// the odds of someone needing to upgrade midway through the lifetime of a connection are very low.
public class HTTPServerUpgradeHandler: ChannelInboundHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private let upgraders: [String: HTTPProtocolUpgrader]
    private let upgradeCompletionHandler: (ChannelHandlerContext) -> Void

    private let httpEncoder: HTTPResponseEncoder?
    private let extraHTTPHandlers: [ChannelHandler]

    /// Whether we've already seen the first request.
    private var seenFirstRequest = false

    /// Whether we're upgrading: if we are, we want to buffer the data until the
    /// upgrade is complete.
    private var upgrading = false
    private var receivedMessages: [NIOAny] = []

    /// Create a `HTTPServerUpgradeHandler`.
    ///
    /// - Parameter upgraders: All `HTTPProtocolUpgrader` objects that this pipeline will be able
    ///     to use to handle HTTP upgrade.
    /// - Parameter httpEncoder: The `HTTPResponseEncoder` encoding responses from this handler and which will
    ///     be removed from the pipeline once the upgrade response is sent. This is used mostly to ensure
    ///     that the pipeline will be in a clean state after upgrade. Pass `nil` to this parameter if for any
    ///     reason you want to keep the `HTTPResponseEncoder` in the pipeline after upgrade.
    /// - Parameter httpDecoder: The `HTTPRequestDecoder` decoding responses that are passed to this handler.
    ///     This is necessary to ensure that no further data is parsed as HTTP when we attempt an upgrade.
    ///     Pass `nil` to this parameter if for any reason you want to keep the `HTTPRequestDecoder` in
    ///     the pipeline after upgrade.
    /// - Parameter upgradeCompletionHandler: A block that will be fired when HTTP upgrade is complete.
    @available(*, deprecated, message: "Please use init(upgraders:httpEncoder:extraHTTPHandlers:upgradeCompletionHandler:)")
    public init(upgraders: [HTTPProtocolUpgrader], httpEncoder: HTTPResponseEncoder?, httpDecoder: HTTPRequestDecoder?, upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) {
        var upgraderMap = [String: HTTPProtocolUpgrader]()
        for upgrader in upgraders {
            upgraderMap[upgrader.supportedProtocol] = upgrader
        }
        self.upgraders = upgraderMap
        self.upgradeCompletionHandler = upgradeCompletionHandler
        self.httpEncoder = httpEncoder

        if let decoder = httpDecoder {
            self.extraHTTPHandlers = [decoder]
        } else {
            self.extraHTTPHandlers = []
        }
    }

    /// Create a `HTTPServerUpgradeHandler`.
    ///
    /// - Parameter upgraders: All `HTTPProtocolUpgrader` objects that this pipeline will be able
    ///     to use to handle HTTP upgrade.
    /// - Parameter httpEncoder: The `HTTPResponseEncoder` encoding responses from this handler and which will
    ///     be removed from the pipeline once the upgrade response is sent. This is used to ensure
    ///     that the pipeline will be in a clean state after upgrade.
    /// - Parameter extraHTTPHandlers: Any other handlers that are directly related to handling HTTP. At the very least
    ///     this should include the `HTTPDecoder`, but should also include any other handler that cannot tolerate
    ///     receiving non-HTTP data.
    /// - Parameter upgradeCompletionHandler: A block that will be fired when HTTP upgrade is complete.
    public init(upgraders: [HTTPProtocolUpgrader], httpEncoder: HTTPResponseEncoder, extraHTTPHandlers: [ChannelHandler], upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) {
        var upgraderMap = [String: HTTPProtocolUpgrader]()
        for upgrader in upgraders {
            upgraderMap[upgrader.supportedProtocol] = upgrader
        }
        self.upgraders = upgraderMap
        self.upgradeCompletionHandler = upgradeCompletionHandler
        self.httpEncoder = httpEncoder
        self.extraHTTPHandlers = extraHTTPHandlers
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if self.upgrading {
            // We're waiting for upgrade to complete: buffer this data.
            self.receivedMessages.append(data)
            return
        }

        // We're trying to remove ourselves from the pipeline but not upgrading, so just pass this on.
        if seenFirstRequest {
            ctx.fireChannelRead(data)
            return
        }

        let requestPart = unwrapInboundIn(data)
        seenFirstRequest = true

        // We should only ever see a request header: by the time the body comes in we should
        // be out of the pipeline. Anything else is an error.
        guard case .head(let request) = requestPart else {
            ctx.fireErrorCaught(HTTPUpgradeErrors.invalidHTTPOrdering)
            notUpgrading(ctx: ctx, data: data)
            return
        }

        // Ok, we have a HTTP request. Check if it's an upgrade. If it's not, we want to pass it on and remove ourselves
        // from the channel pipeline.
        let requestedProtocols = request.headers.getCanonicalForm("upgrade")
        guard requestedProtocols.count > 0 else {
            notUpgrading(ctx: ctx, data: data)
            return
        }

        // Cool, this is an upgrade! Let's go.
        if !handleUpgrade(ctx: ctx, request: request, requestedProtocols: requestedProtocols) {
            notUpgrading(ctx: ctx, data: data)
        }
    }

    /// The core of the upgrade handling logic.
    private func handleUpgrade(ctx: ChannelHandlerContext, request: HTTPRequestHead, requestedProtocols: [String]) -> Bool {
        let connectionHeader = Set(request.headers.getCanonicalForm("connection").map { $0.lowercased() })
        let allHeaderNames = Set(request.headers.map { $0.name.lowercased() })

        for proto in requestedProtocols {
            guard let upgrader = upgraders[proto] else {
                continue
            }

            let requiredHeaders = Set(upgrader.requiredUpgradeHeaders.map { $0.lowercased() })
            guard requiredHeaders.isSubset(of: allHeaderNames) && requiredHeaders.isSubset(of: connectionHeader) else {
                continue
            }

            var responseHeaders = buildUpgradeHeaders(protocol: proto)
            do {
                responseHeaders = try upgrader.buildUpgradeResponse(upgradeRequest: request, initialResponseHeaders: responseHeaders)
            } catch {
                // We should fire this error so the user can log it, but keep going.
                ctx.fireErrorCaught(error)
                continue
            }

            // We are now upgrading, any further data should be buffered and replayed.
            self.upgrading = true

            // Before we finish the upgrade we have to remove the HTTPDecoder and any other non-Encoder HTTP
            // handlers from the pipeline, to prevent them parsing any more data. We'll buffer the data until
            // that completes.
            // While there are a lot of Futures involved here it's quite possible that all of this code will
            // actually complete synchronously: we just want to program for the possibility that it won't.
            // Once that's done, we send the upgrade response, then remove the HTTP encoder, then call the
            // internal handler, then call the user code, and then finally when the user code is done we do
            // our final cleanup steps, namely we replay the received data we buffered in the meantime and
            // then remove ourselves from the pipeline.
            _ = self.removeExtraHandlers(ctx: ctx).then {
                self.sendUpgradeResponse(ctx: ctx, upgradeRequest: request, responseHeaders: responseHeaders)
            }.then {
                self.removeHandler(ctx: ctx, handler: self.httpEncoder)
            }.map { (_: Bool) in
                self.upgradeCompletionHandler(ctx)
            }.then {
                upgrader.upgrade(ctx: ctx, upgradeRequest: request)
            }.map {
                ctx.fireUserInboundEventTriggered(HTTPUpgradeEvents.upgradeComplete(toProtocol: proto, upgradeRequest: request))

                self.upgrading = false

                // We unbuffer any buffered data here and, if we sent any,
                // we also fire readComplete.
                let bufferedMessages = self.receivedMessages
                self.receivedMessages = []
                bufferedMessages.forEach { ctx.fireChannelRead($0) }
                if bufferedMessages.count > 0 {
                    ctx.fireChannelReadComplete()
                }
            }.then {
                ctx.pipeline.remove(ctx: ctx)
            }

            return true
        }

        return false
    }

    /// Sends the 101 Switching Protocols response for the pipeline.
    private func sendUpgradeResponse(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead, responseHeaders: HTTPHeaders) -> EventLoopFuture<Void> {
        var response = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .switchingProtocols)
        response.headers = responseHeaders
        return ctx.writeAndFlush(wrapOutboundOut(HTTPServerResponsePart.head(response)))
    }

    /// Called when we know we're not upgrading. Passes the data on and then removes this object from the pipeline.
    private func notUpgrading(ctx: ChannelHandlerContext, data: NIOAny) {
        assert(self.receivedMessages.count == 0)
        ctx.fireChannelRead(data)
        _ = ctx.pipeline.remove(ctx: ctx)
    }

    /// Builds the initial mandatory HTTP headers for HTTP ugprade responses.
    private func buildUpgradeHeaders(`protocol`: String) -> HTTPHeaders {
        return HTTPHeaders([("connection", "upgrade"), ("upgrade", `protocol`)])
    }

    /// Removes the given channel handler from the channel pipeline.
    private func removeHandler(ctx: ChannelHandlerContext, handler: ChannelHandler?) -> EventLoopFuture<Bool> {
        if let handler = handler {
            return ctx.pipeline.remove(handler: handler)
        } else {
            return ctx.eventLoop.newSucceededFuture(result: true)
        }
    }

    /// Removes any extra HTTP-related handlers from the channel pipeline.
    private func removeExtraHandlers(ctx: ChannelHandlerContext) -> EventLoopFuture<Void> {
        guard self.extraHTTPHandlers.count > 0 else {
            return ctx.eventLoop.newSucceededFuture(result: ())
        }

        return EventLoopFuture<Void>.andAll(self.extraHTTPHandlers.map { ctx.pipeline.remove(handler: $0).map { (_: Bool) in () }},
                                            eventLoop: ctx.eventLoop)
    }
}
