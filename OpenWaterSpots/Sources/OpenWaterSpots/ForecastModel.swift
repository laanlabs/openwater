import Foundation

/// Which numerical model answers when the app asks about wind.
///
/// Open-Meteo will pick for itself — that is `best_match`, and it is the
/// right default, because the best model for a point is usually the finest
/// one that covers it. But the models disagree, and near a coast they
/// disagree by more than the difference between a session and a drive home:
/// asked about the Golden Gate on one afternoon, ICON said three knots,
/// ECMWF four, MET Norway six and GFS seven. A rider who has learned which
/// model reads their water best should be able to say so.
///
/// The regional entries are the `_seamless` variants on purpose: each
/// blends its own high-resolution domain with its parent global model, so
/// picking AROME outside France answers from ARPEGE rather than answering
/// with nothing. No dead ends, wherever the map is pointed.
public enum ForecastModel: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case ecmwf
    case gfs
    case icon
    case meteofrance
    case ukmo
    case metno

    public var id: String { rawValue }

    /// Open-Meteo's own identifier; nil is "you choose".
    public var apiValue: String? {
        switch self {
        case .automatic: nil
        case .ecmwf: "ecmwf_ifs025"
        case .gfs: "gfs_seamless"
        case .icon: "icon_seamless"
        case .meteofrance: "meteofrance_seamless"
        case .ukmo: "ukmo_seamless"
        case .metno: "metno_seamless"
        }
    }

    public var name: String {
        switch self {
        case .automatic: "Automatic selection"
        case .ecmwf: "ECMWF"
        case .gfs: "NOAA GFS"
        case .icon: "DWD ICON"
        case .meteofrance: "Météo-France"
        case .ukmo: "UK Met Office"
        case .metno: "MET Norway"
        }
    }

    /// The resolutions are the models' own, not a competitor's marketing:
    /// a seamless blend is named by the finest domain it can reach and the
    /// global one it falls back to.
    public var detail: String {
        switch self {
        case .automatic: "Best model available for each point"
        case .ecmwf: "Global, 25 km"
        case .gfs: "Global 13 km · 3 km HRRR over the US"
        case .icon: "Global 11 km · 7 km Europe · 2 km Germany"
        case .meteofrance: "Global 11 km · 1.3 km AROME over France"
        case .ukmo: "Global 10 km · 2 km UKV over the UK"
        case .metno: "1 km over the Nordics"
        }
    }

    /// The short name a caption wears, where "Open-Meteo model" used to sit.
    public var captionName: String {
        self == .automatic ? "Open-Meteo model" : name
    }

    // MARK: The preference

    /// One choice for the whole app, read wherever a wind URL is built —
    /// `UserDefaults` rather than an injected setting because the fetchers
    /// are free functions on `OpenMeteo`, reachable from any actor, and a
    /// defaults read is safe from all of them.
    private static let key = "spots.forecastModel"

    public static var selected: ForecastModel {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(ForecastModel.init(rawValue:)) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Appended to every wind request. Nothing is appended for automatic,
    /// so the default URL — and everything already cached against it —
    /// stays exactly what it was.
    public static var queryItem: URLQueryItem? {
        selected.apiValue.map { URLQueryItem(name: "models", value: $0) }
    }
}
