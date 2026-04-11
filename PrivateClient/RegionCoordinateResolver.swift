import CoreLocation
import Foundation

struct MapRegion: Identifiable {
    let region: PIARegion
    let coordinate: CLLocationCoordinate2D

    var id: String {
        region.selectionID
    }
}

enum RegionCoordinateResolver {
    static func coordinate(for region: PIARegion) -> CLLocationCoordinate2D? {
        if let exact = GeneratedRegionCoordinates.regions[regionKey(for: region)] {
            return exact
        }
        
        if let capital = countryCapitals[region.country.uppercased()] {
            // Use deterministic offsets when falling back to a capital to avoid stacking multiple pins
            let (latOffset, lonOffset) = deterministicOffsets(for: region.selectionID)
            return CLLocationCoordinate2D(
                latitude: max(-85, min(85, capital.latitude + latOffset)),
                longitude: wrappedLongitude(capital.longitude + lonOffset)
            )
        }

        return nil
    }
}

private extension RegionCoordinateResolver {
    static let countryCapitals: [String: CLLocationCoordinate2D] = [
        "AD": .init(latitude: 42.5000, longitude: 1.5200),
        "AE": .init(latitude: 24.4700, longitude: 54.3700),
        "AL": .init(latitude: 41.3200, longitude: 19.8200),
        "AM": .init(latitude: 40.1700, longitude: 44.5000),
        "AR": .init(latitude: -34.5800, longitude: -58.6700),
        "AT": .init(latitude: 48.2000, longitude: 16.3700),
        "AU": .init(latitude: -35.2700, longitude: 149.1300),
        "BA": .init(latitude: 43.8700, longitude: 18.4200),
        "BD": .init(latitude: 23.7200, longitude: 90.4000),
        "BE": .init(latitude: 50.8300, longitude: 4.3300),
        "BG": .init(latitude: 42.6800, longitude: 23.3200),
        "BO": .init(latitude: -19.0200, longitude: -65.2600),
        "BR": .init(latitude: -15.7900, longitude: -47.8800),
        "BS": .init(latitude: 25.0800, longitude: -77.3500),
        "CA": .init(latitude: 45.4200, longitude: -75.7000),
        "CH": .init(latitude: 46.9200, longitude: 7.4700),
        "CL": .init(latitude: -33.4500, longitude: -70.6700),
        "CN": .init(latitude: 39.9200, longitude: 116.3800),
        "CO": .init(latitude: 4.7100, longitude: -74.0700),
        "CR": .init(latitude: 9.9300, longitude: -84.0900),
        "CY": .init(latitude: 35.1700, longitude: 33.3700),
        "CZ": .init(latitude: 50.0800, longitude: 14.4700),
        "DE": .init(latitude: 52.5200, longitude: 13.4000),
        "DK": .init(latitude: 55.6700, longitude: 12.5800),
        "DZ": .init(latitude: 36.7500, longitude: 3.0500),
        "EC": .init(latitude: -0.2200, longitude: -78.5000),
        "EE": .init(latitude: 59.4300, longitude: 24.7200),
        "EG": .init(latitude: 30.0500, longitude: 31.2500),
        "ES": .init(latitude: 40.4000, longitude: -3.6800),
        "FI": .init(latitude: 60.1700, longitude: 24.9300),
        "FR": .init(latitude: 48.8700, longitude: 2.3300),
        "GB": .init(latitude: 51.5000, longitude: -0.0800),
        "GE": .init(latitude: 41.6800, longitude: 44.8300),
        "GL": .init(latitude: 64.1800, longitude: -51.7500),
        "GR": .init(latitude: 37.9800, longitude: 23.7300),
        "GT": .init(latitude: 14.6200, longitude: -90.5200),
        "HK": .init(latitude: 22.2670, longitude: 114.1880),
        "HR": .init(latitude: 45.8000, longitude: 16.0000),
        "HU": .init(latitude: 47.5000, longitude: 19.0800),
        "ID": .init(latitude: -6.1700, longitude: 106.8200),
        "IE": .init(latitude: 53.3200, longitude: -6.2300),
        "IL": .init(latitude: 31.7700, longitude: 35.2300),
        "IM": .init(latitude: 54.1500, longitude: -4.4800),
        "IN": .init(latitude: 28.6000, longitude: 77.2000),
        "IS": .init(latitude: 64.1500, longitude: -21.9500),
        "IT": .init(latitude: 41.9000, longitude: 12.4800),
        "JP": .init(latitude: 35.6800, longitude: 139.7500),
        "KH": .init(latitude: 11.5500, longitude: 104.9200),
        "KR": .init(latitude: 37.5500, longitude: 126.9800),
        "KZ": .init(latitude: 51.1600, longitude: 71.4500),
        "LI": .init(latitude: 47.1300, longitude: 9.5200),
        "LK": .init(latitude: 6.8900, longitude: 79.9000),
        "LT": .init(latitude: 54.6800, longitude: 25.3200),
        "LU": .init(latitude: 49.6000, longitude: 6.1200),
        "LV": .init(latitude: 56.9500, longitude: 24.1000),
        "MA": .init(latitude: 34.0200, longitude: -6.8200),
        "MC": .init(latitude: 43.7300, longitude: 7.4200),
        "MD": .init(latitude: 47.0100, longitude: 28.9000),
        "ME": .init(latitude: 42.4300, longitude: 19.2700),
        "MK": .init(latitude: 42.0000, longitude: 21.4300),
        "MN": .init(latitude: 47.9200, longitude: 106.9100),
        "MT": .init(latitude: 35.8800, longitude: 14.5000),
        "MX": .init(latitude: 19.4300, longitude: -99.1300),
        "MY": .init(latitude: 3.1700, longitude: 101.7000),
        "NG": .init(latitude: 9.0800, longitude: 7.5300),
        "NL": .init(latitude: 52.3500, longitude: 4.9200),
        "NO": .init(latitude: 59.9200, longitude: 10.7500),
        "NP": .init(latitude: 27.7200, longitude: 85.3200),
        "NZ": .init(latitude: -41.3000, longitude: 174.7800),
        "PA": .init(latitude: 8.9700, longitude: -79.5300),
        "PE": .init(latitude: -12.0500, longitude: -77.0500),
        "PH": .init(latitude: 14.6000, longitude: 120.9700),
        "PL": .init(latitude: 52.2500, longitude: 21.0000),
        "PT": .init(latitude: 38.7200, longitude: -9.1300),
        "QA": .init(latitude: 25.2800, longitude: 51.5300),
        "RO": .init(latitude: 44.4300, longitude: 26.1000),
        "RS": .init(latitude: 44.8300, longitude: 20.5000),
        "SA": .init(latitude: 24.6500, longitude: 46.7000),
        "SE": .init(latitude: 59.3300, longitude: 18.0500),
        "SG": .init(latitude: 1.2800, longitude: 103.8500),
        "SI": .init(latitude: 46.0500, longitude: 14.5200),
        "SK": .init(latitude: 48.1500, longitude: 17.1200),
        "TR": .init(latitude: 39.9300, longitude: 32.8700),
        "TW": .init(latitude: 25.0300, longitude: 121.5200),
        "UA": .init(latitude: 50.4300, longitude: 30.5200),
        "US": .init(latitude: 38.8900, longitude: -77.0500),
        "UY": .init(latitude: -34.8500, longitude: -56.1700),
        "VE": .init(latitude: 10.4800, longitude: -66.8700),
        "VN": .init(latitude: 21.0300, longitude: 105.8500),
        "ZA": .init(latitude: -25.7000, longitude: 28.2200)
    ]

    static func regionKey(for region: PIARegion) -> String {
        "\(region.id)|\(region.name)".lowercased()
    }

    static func deterministicOffsets(for key: String) -> (Double, Double) {
        let hash = key.unicodeScalars.reduce(UInt64(5381)) { acc, scalar in
            ((acc << 5) &+ acc) &+ UInt64(scalar.value)
        }
        let latBucket = Int(hash % 1000)
        let lonBucket = Int((hash / 1000) % 1000)
        let latitudeOffset = (Double(latBucket) / 1000.0 - 0.5) * 0.4
        let longitudeOffset = (Double(lonBucket) / 1000.0 - 0.5) * 0.6
        return (latitudeOffset, longitudeOffset)
    }

    static func wrappedLongitude(_ longitude: Double) -> Double {
        var value = longitude
        while value > 180 {
            value -= 360
        }
        while value < -180 {
            value += 360
        }
        return value
    }
}
