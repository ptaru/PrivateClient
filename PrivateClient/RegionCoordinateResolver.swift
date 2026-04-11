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
        if let exactByID = manualRegionOverrides[region.id.lowercased()] {
            return exactByID
        }
        let haystack = normalized("\(region.id) \(region.name)")

        if let city = firstMatch(in: cityCenters, haystack: haystack) {
            return city
        }
        if let subRegion = firstMatch(in: regionalCenters, haystack: haystack) {
            return subRegion
        }

        if let capital = countryCapitals[region.country.uppercased()] {
            return capital
        }

        if let exact = GeneratedRegionCoordinates.regions[regionKey(for: region)] {
            return exact
        }
        guard let base = GeneratedRegionCoordinates.countryCentroids[region.country.uppercased()] else {
            return nil
        }
        let (latOffset, lonOffset) = deterministicOffsets(for: region.selectionID)
        let latitude = max(-85, min(85, base.latitude + latOffset))
        let longitude = wrappedLongitude(base.longitude + lonOffset)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension RegionCoordinateResolver {
    static let manualRegionOverrides: [String: CLLocationCoordinate2D] = [
        "uk_manchester": .init(latitude: 53.4808, longitude: -2.2426),
        "uk_southampton": .init(latitude: 50.9097, longitude: -1.4044),
        "ad": .init(latitude: 42.5063, longitude: 1.5218),
        "monaco": .init(latitude: 43.7384, longitude: 7.4246),
        "us_seattle": .init(latitude: 47.6062, longitude: -122.3321),
        "us_new_hampshire-pf": .init(latitude: 43.2081, longitude: -71.5376),
        "us_massachusetts-pf": .init(latitude: 42.4072, longitude: -71.3824),
        "au_adelaide-pf": .init(latitude: -34.9285, longitude: 138.6007),
        "au_brisbane-pf": .init(latitude: -27.4698, longitude: 153.0251),
        "aus_perth": .init(latitude: -31.9523, longitude: 115.8613),
        "au_australia-so": .init(latitude: -35.2700, longitude: 149.1300), // Canberra
        "italy_2": .init(latitude: 41.9000, longitude: 12.4800), // Rome
        "us-streaming": .init(latitude: 38.9072, longitude: -77.0369), // Washington DC
        "uk_2": .init(latitude: 52.4862, longitude: -1.8904) // Birmingham
    ]

    static let cityCenters: [String: CLLocationCoordinate2D] = [
        "washington dc": .init(latitude: 38.9072, longitude: -77.0369),
        "silicon valley": .init(latitude: 37.3875, longitude: -122.0575),
        "salt lake city": .init(latitude: 40.7608, longitude: -111.8910),
        "las vegas": .init(latitude: 36.1699, longitude: -115.1398),
        "new york": .init(latitude: 40.7128, longitude: -74.0060),
        "seattle": .init(latitude: 47.6062, longitude: -122.3321),
        "wilmington": .init(latitude: 39.7391, longitude: -75.5398),
        "baltimore": .init(latitude: 39.2904, longitude: -76.6122),
        "honolulu": .init(latitude: 21.3069, longitude: -157.8583),
        "atlanta": .init(latitude: 33.7490, longitude: -84.3880),
        "houston": .init(latitude: 29.7604, longitude: -95.3698),
        "chicago": .init(latitude: 41.8781, longitude: -87.6298),
        "denver": .init(latitude: 39.7392, longitude: -104.9903),
        "valencia": .init(latitude: 39.4699, longitude: -0.3763),
        "berlin": .init(latitude: 52.5200, longitude: 13.4050),
        "frankfurt": .init(latitude: 50.1109, longitude: 8.6821),
        "copenhagen": .init(latitude: 55.6761, longitude: 12.5683),
        "adelaide": .init(latitude: -34.9285, longitude: 138.6007),
        "brisbane": .init(latitude: -27.4698, longitude: 153.0251),
        "melbourne": .init(latitude: -37.8136, longitude: 144.9631),
        "perth": .init(latitude: -31.9523, longitude: 115.8613),
        "sydney": .init(latitude: -33.8688, longitude: 151.2093),
        "milano": .init(latitude: 45.4642, longitude: 9.1900),
        "milan": .init(latitude: 45.4642, longitude: 9.1900),
        "toronto": .init(latitude: 43.6532, longitude: -79.3832),
        "montreal": .init(latitude: 45.5017, longitude: -73.5673),
        "vancouver": .init(latitude: 49.2827, longitude: -123.1207),
        "macao": .init(latitude: 22.1987, longitude: 113.5439)
    ]

    static let regionalCenters: [String: CLLocationCoordinate2D] = [
        "us east": .init(latitude: 39.9526, longitude: -75.1652),
        "us west": .init(latitude: 36.7783, longitude: -119.4179),
        "ontario": .init(latitude: 50.0000, longitude: -85.0000),
        "alabama": .init(latitude: 32.8067, longitude: -86.7911),
        "alaska": .init(latitude: 61.3707, longitude: -152.4044),
        "arkansas": .init(latitude: 34.9697, longitude: -92.3731),
        "california": .init(latitude: 36.7783, longitude: -119.4179),
        "connecticut": .init(latitude: 41.6032, longitude: -73.0877),
        "florida": .init(latitude: 27.6648, longitude: -81.5158),
        "idaho": .init(latitude: 44.0682, longitude: -114.7420),
        "iowa": .init(latitude: 41.8780, longitude: -93.0977),
        "kansas": .init(latitude: 39.0119, longitude: -98.4842),
        "kentucky": .init(latitude: 37.8393, longitude: -84.2700),
        "louisiana": .init(latitude: 30.9843, longitude: -91.9623),
        "maine": .init(latitude: 45.2538, longitude: -69.4455),
        "massachusetts": .init(latitude: 42.4072, longitude: -71.3824),
        "michigan": .init(latitude: 44.3148, longitude: -85.6024),
        "minnesota": .init(latitude: 46.7296, longitude: -94.6859),
        "mississippi": .init(latitude: 32.3547, longitude: -89.3985),
        "missouri": .init(latitude: 37.9643, longitude: -91.8318),
        "montana": .init(latitude: 46.8797, longitude: -110.3626),
        "nebraska": .init(latitude: 41.4925, longitude: -99.9018),
        "new hampshire": .init(latitude: 43.1939, longitude: -71.5724),
        "new mexico": .init(latitude: 34.5199, longitude: -105.8701),
        "north carolina": .init(latitude: 35.7596, longitude: -79.0193),
        "north dakota": .init(latitude: 47.5515, longitude: -101.0020),
        "ohio": .init(latitude: 40.4173, longitude: -82.9071),
        "oklahoma": .init(latitude: 35.0078, longitude: -97.0929),
        "oregon": .init(latitude: 43.8041, longitude: -120.5542),
        "pennsylvania": .init(latitude: 41.2033, longitude: -77.1945),
        "rhode island": .init(latitude: 41.5801, longitude: -71.4774),
        "south carolina": .init(latitude: 33.8361, longitude: -81.1637),
        "south dakota": .init(latitude: 43.9695, longitude: -99.9018),
        "tennessee": .init(latitude: 35.5175, longitude: -86.5804),
        "texas": .init(latitude: 31.9686, longitude: -99.9018),
        "vermont": .init(latitude: 44.5588, longitude: -72.5778),
        "virginia": .init(latitude: 37.4316, longitude: -78.6569),
        "west virginia": .init(latitude: 38.5976, longitude: -80.4549),
        "wisconsin": .init(latitude: 43.7844, longitude: -88.7879),
        "wyoming": .init(latitude: 43.0760, longitude: -107.2903),
        "indiana": .init(latitude: 40.2672, longitude: -86.1349)
    ]

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

    static func firstMatch(
        in map: [String: CLLocationCoordinate2D],
        haystack: String
    ) -> CLLocationCoordinate2D? {
        for key in map.keys.sorted(by: { $0.count > $1.count }) {
            if haystack.contains(key) {
                return map[key]
            }
        }
        return nil
    }

    static func normalized(_ input: String) -> String {
        let lower = input.lowercased()
        let mapped = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        return String(mapped).replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
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
