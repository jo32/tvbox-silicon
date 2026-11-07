import Foundation
import Testing
@testable import TVCore

@Test func liveChatsFollowThePlatformsProtocol() {
    #expect(LiveChats.make("bilibili", room: "21452505") is BilibiliLiveChat)
    #expect(LiveChats.make("douyu", room: "9999") is DouyuLiveChat)
    #expect(LiveChats.make("huya", room: "1995") is HuyaLiveChat)
    #expect(LiveChats.make(nil, room: "9999") == nil)
    #expect(LiveChats.make("douyin", room: "9999") == nil)
    #expect(LiveChats.make("douyu", room: "lpl") == nil)
}

@Test func douyuPacketsFrameSTTMessages() {
    let packet = DouyuLiveChat.packet("type@=mrkl/")
    // Length (from the second copy) twice, type 689, two zero bytes, the text and a NUL.
    #expect([UInt8](packet) == [20, 0, 0, 0, 20, 0, 0, 0, 0xB1, 0x02, 0, 0] + Array("type@=mrkl/".utf8) + [0])
    #expect(DouyuLiveChat.messages(packet) == [["type": "mrkl"]])
}

@Test func douyuChatMessagesBecomeComments() {
    func server(_ text: String) -> Data {
        let body = Data(text.utf8) + [0]
        var data = Data()
        for value in [UInt32(8 + body.count), UInt32(8 + body.count)] { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data + [0xB2, 0x02, 0, 0] + body
    }
    // Two packets in one frame; `@S` and `@A` stand for `/` and `@`.
    let frame = server("type@=chatmsg/rid@=9999/nn@=viewer/txt@=1@S2 @Ahost/col@=2/") + server("type@=uenter/rid@=9999/")
    let messages = DouyuLiveChat.messages(frame)
    #expect(messages.count == 2)
    #expect(messages[0]["txt"] == "1/2 @host")
    let comment = DouyuLiveChat.comment(messages[0])
    #expect(comment?.text == "1/2 @host")
    #expect(comment?.color == 0x1E87F0)
    #expect(DouyuLiveChat.comment(messages[1]) == nil)
    #expect(DouyuLiveChat.comment(DouyuLiveChat.fields("type@=chatmsg/txt@=/")) == nil)
    #expect(DouyuLiveChat.comment(DouyuLiveChat.fields("type@=chatmsg/txt@=hi/"))?.color == 0xFFFFFF)
    #expect(DouyuLiveChat.comment(DouyuLiveChat.fields("type@=chatmsg/txt@=hi/col@=42/"))?.color == 0xFFFFFF)
    // A cut-off frame yields what is whole.
    #expect(DouyuLiveChat.messages(frame.prefix(frame.count - 3)).count == 1)
}

@Test func huyaRegistersWithTheRoomsIds() {
    let register = HuyaLiveChat.register(yyid: 2_272_348_727, channel: 2_272_316_519, subchannel: 2_272_316_519)
    var reader = TarsReader(register)
    let command = reader.fields()
    #expect(command?[0]?.int == 1)
    var userReader = TarsReader(command?[1]?.data ?? Data())
    let user = userReader.fields()
    #expect(user?[0]?.int == 2_272_348_727)
    #expect(user?[1]?.int == 1)
    #expect(user?[2]?.string == "")
    #expect(user?[4]?.int == 2_272_316_519)
    #expect(user?[5]?.int == 2_272_316_519)
    #expect(user?[7]?.int == 0)
    // The fixed heartbeat reads as a command too.
    var heartbeat = TarsReader(HuyaLiveChat.heartbeat)
    #expect(heartbeat.fields() != nil)
}

@Test func huyaPushedCommentsBecomeComments() {
    func pushed(uri: Int64, _ message: Data) -> Data {
        var push = TarsWriter()
        push.int(0, tag: 0); push.int(uri, tag: 1); push.bytes(message, tag: 2); push.int(0, tag: 3)
        var command = TarsWriter()
        command.int(7, tag: 0); command.bytes(push.data, tag: 1)
        return command.data
    }
    func notice(_ text: String, color: Int64) -> Data {
        // Sender {uid, imid, nickname} as a struct (type 10 … 11), a few fields, the text, then the format struct.
        var sender = TarsWriter()
        sender.int(123_456_789_012, tag: 0); sender.int(0, tag: 1); sender.string("viewer", tag: 2)
        var format = TarsWriter()
        format.int(color, tag: 0); format.int(4, tag: 1)
        var notice = TarsWriter()
        notice.int(0, tag: 1); notice.int(0, tag: 2); notice.string(text, tag: 3); notice.int(-1, tag: 4)
        return Data([0x0A]) + sender.data + [0x0B] + notice.data + [0x6A] + format.data + [0x0B]
    }
    let comment = HuyaLiveChat.comment(pushed(uri: 1400, notice("666 主播好", color: 0x9AFF02)))
    #expect(comment?.text == "666 主播好")
    #expect(comment?.color == 0x9AFF02)
    #expect(HuyaLiveChat.comment(pushed(uri: 1400, notice("hi", color: -1)))?.color == 0xFFFFFF)
    #expect(HuyaLiveChat.comment(pushed(uri: 8006, notice("hi", color: 0))) == nil)
    #expect(HuyaLiveChat.comment(HuyaLiveChat.heartbeat) == nil)
    #expect(HuyaLiveChat.comment(Data([0x0D, 0x00])) == nil)
}

@Test func tarsKeepsLongStringsAndNegativeNumbers() {
    var writer = TarsWriter()
    let long = String(repeating: "弹", count: 200)
    writer.int(-2, tag: 1); writer.int(-40_000, tag: 2); writer.int(Int64.min, tag: 20); writer.string(long, tag: 3)
    var reader = TarsReader(writer.data)
    let fields = reader.fields()
    #expect(fields?[1]?.int == -2)
    #expect(fields?[2]?.int == -40_000)
    #expect(fields?[20]?.int == Int64.min)
    #expect(fields?[3]?.string == long)
}
