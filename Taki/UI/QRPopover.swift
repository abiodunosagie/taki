import CoreImage.CIFilterBuiltins
import SwiftUI

/// QR code of the LAN address, so a phone on the same Wi-Fi opens the dev server.
struct QRPopover: View {
    let port: Int?

    var body: some View {
        VStack(spacing: 10) {
            if let port, let ip = LAN.address() {
                let url = "http://\(ip):\(port)"
                if let img = qr(url) {
                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 180, height: 180)
                }
                Text(url).font(Theme.mono)
                Text("The server has to listen on all interfaces, for example with --host 0.0.0.0.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 200)
            } else {
                Text(port == nil ? "Start a service first." : "No Wi-Fi address found.").padding()
            }
        }
        .padding(16)
    }

    private func qr(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

enum LAN {
    /// The Mac's IPv4 address on Wi-Fi or Ethernet (an `en` interface).
    static func address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard a.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: a.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a.ifa_addr, socklen_t(a.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}
