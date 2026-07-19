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

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        peer.close(promise: nil)
    }
}
