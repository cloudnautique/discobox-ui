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

@Test func terminalURLsUseTheBoxMappingAndPreservePathQueryAndFragment() throws {
    let snapshot = try JSONDecoder().decode(ServiceForwardSnapshot.self, from: Data(#"{"ports":[{"port":8080,"local":8081,"protocol":"tcp","serviceId":"web","serviceName":"Web"},{"port":8081,"local":8082,"protocol":"http","serviceId":"api","serviceName":"API"},{"port":9000,"local":9001,"protocol":"udp","serviceId":"","serviceName":""}]}"#.utf8))
    for host in ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "[::]"] {
        let url = try #require(URL(string: "http://\(host):8080/docs?q=a%20b#intro"))
        #expect(ForwardedServiceURL.resolve(url, ports: snapshot.ports)?.absoluteString == "http://127.0.0.1:8081/docs?q=a%20b#intro")
    }
    let api = try #require(URL(string: "https://localhost:8081/api"))
    #expect(ForwardedServiceURL.resolve(api, ports: snapshot.ports)?.absoluteString == "https://127.0.0.1:8082/api")
    let missing = try #require(URL(string: "http://localhost:8090/"))
    #expect(ForwardedServiceURL.resolve(missing, ports: snapshot.ports) == nil)
    let udp = try #require(URL(string: "http://localhost:9000/"))
    #expect(ForwardedServiceURL.resolve(udp, ports: snapshot.ports) == nil)
    for address in ["https://example.com:8080/docs", "http://localhost.example.com:8080/", "http://192.168.1.1:8080/"] {
        let url = try #require(URL(string: address))
        #expect(ForwardedServiceURL.resolve(url, ports: snapshot.ports) == url)
    }
    #expect(ForwardedServiceURL.sandboxPort(URL(string: "http://localhost/")!) == 80)
    #expect(ForwardedServiceURL.sandboxPort(URL(string: "https://localhost/")!) == 443)
    #expect(ForwardedServiceURL.sandboxPort(URL(string: "ssh://localhost:8080")!) == nil)
}

@Test func box8081CanMapToMac8080() throws {
    let snapshot = try JSONDecoder().decode(ServiceForwardSnapshot.self, from: Data(#"{"ports":[{"port":8081,"local":8080,"protocol":"http","serviceId":"web","serviceName":"Web"}]}"#.utf8))
    #expect(snapshot.ports[0].browserURL?.absoluteString == "http://127.0.0.1:8080")
    let printed = try #require(URL(string: "http://localhost:8081/docs"))
    #expect(ForwardedServiceURL.resolve(printed, ports: snapshot.ports)?.absoluteString == "http://127.0.0.1:8080/docs")
}
