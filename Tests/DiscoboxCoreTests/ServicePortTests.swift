import Foundation
import Testing
@testable import DiscoboxCore

@Test func serviceLinksUseForwardedPortAndOnlyWebProtocols() throws {
    let snapshot = try JSONDecoder().decode(ServiceForwardSnapshot.self, from: Data(#"{"ports":[{"port":7100,"local":7101,"protocol":"https","serviceId":"ai.discobox.desktop","serviceName":"Desktop"},{"port":5432,"local":5433,"protocol":"tcp","serviceId":"database","serviceName":"Database"},{"port":5432,"local":5432,"protocol":"udp","serviceId":"","serviceName":""}]}"#.utf8))
    #expect(snapshot.ports[0].isDesktop)
    #expect(snapshot.ports[0].browserURL?.absoluteString == "https://127.0.0.1:7101")
    #expect(snapshot.ports[1].browserURL == nil)
    #expect(snapshot.ports[1].browserURL(as: "http")?.absoluteString == "http://127.0.0.1:5433")
    #expect(snapshot.ports[1].browserURL(as: "https")?.absoluteString == "https://127.0.0.1:5433")
    #expect(snapshot.ports[1].browserURL(as: "file") == nil)
    #expect(snapshot.ports[2].browserURL(as: "http") == nil)
    #expect(snapshot.ports[2].browserURL == nil)
    #expect(snapshot.ports[1].id != snapshot.ports[2].id)
}
