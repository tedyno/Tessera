import NIOCore

/// Forwards inbound `ByteBuffer`s to a peer channel. Holds only a `Channel`
/// reference (not a handler context), and `Channel.writeAndFlush`/`close` are
/// thread-safe, so this works even when the two channels live on different event
/// loops (the local TCP channel vs. the SSH direct-tcpip channel).
final class ForwardHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    /// Requests reads explicitly so forwarding doesn't depend on either channel
    /// having `autoRead` enabled — the local socket and the SSH child channel are
    /// created by different layers and don't have to agree on it.
    func channelActive(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        peer.close(promise: nil)
    }
}
