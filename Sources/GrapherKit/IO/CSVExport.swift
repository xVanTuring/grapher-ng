import Foundation

/// Dumps the sampled points of every visible curve as a long-format CSV, which
/// is the shape spreadsheets and plotting scripts both accept without fuss.
public enum CSVExport {
    public static func write(curves: [ProbeCurve], to url: URL) throws {
        var output = "layer,x,y\n"
        output.reserveCapacity(curves.reduce(0) { $0 + $1.segments.reduce(0) { $0 + $1.count } } * 32 + 32)
        for curve in curves {
            let name = curve.layerName.replacingOccurrences(of: "\"", with: "\"\"")
            let quoted = name.contains(",") || name.contains("\"") ? "\"\(name)\"" : name
            for segment in curve.segments {
                for point in segment where point.x.isFinite && point.y.isFinite {
                    output += "\(quoted),\(point.x),\(point.y)\n"
                }
            }
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func string(curves: [ProbeCurve]) -> String {
        var output = "layer,x,y\n"
        for curve in curves {
            for segment in curve.segments {
                for point in segment where point.x.isFinite && point.y.isFinite {
                    output += "\(curve.layerName),\(point.x),\(point.y)\n"
                }
            }
        }
        return output
    }
}
