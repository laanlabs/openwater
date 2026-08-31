import Foundation

/// The shape of a sampled wind field.
///
/// Seven by nine points over whatever rectangle is being asked about — one
/// batched request to Open-Meteo, which takes coordinate lists, so the whole
/// field costs what a single point costs. The number is a compromise the
/// wash and the flow map both live with: coarse enough that the request
/// stays one request, fine enough that a sea breeze and the lull behind a
/// headland are two different colours.
///
/// It lives here rather than on either screen because both draw the same
/// field, and the cell builder that reads it runs off the main actor.
public nonisolated enum WindField: Sendable {
    public static let columns = 7
    public static let rows = 9
}
