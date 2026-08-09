#if DEBUG
import Foundation
import OpenWaterCore

/// The test recordings, put on every debug build.
///
/// Tuning the analysis means comparing what the app shows against
/// `openWaterTests/Expectations/test-N.md`, and that only works if the same
/// ten sessions are on whatever device is to hand. Loading them by hand meant
/// ten trips through the import sheet on every fresh install, so they ride
/// along with the build instead.
///
/// **The recordings are not in the repository.** `openWater/DevSeed/` is
/// gitignored; `scripts/sync-dev-seed.sh` fills it from `testdata/`, and
/// Xcode's synchronised group picks up whatever is there at build time. On a
/// clone with no recordings the folder is empty, this finds nothing and does
/// nothing — which is the correct behaviour, not a failure.
///
/// Debug only, by the `#if` around the whole file. A release build has no
/// seeding code in it at all rather than code that decides not to run.
enum DevSeed {

    /// Import any bundled session that is not already here.
    ///
    /// Keyed on title, so this is safe to run on every launch: the second
    /// launch finds all ten present and does nothing. Without that check a
    /// week of debugging would leave seventy copies of test-5.
    @MainActor
    static func loadIfNeeded(into library: SessionLibrary) {
        let archives = Bundle.main.urls(forResourcesWithExtension: "openwater",
                                        subdirectory: nil) ?? []
        guard !archives.isEmpty else { return }

        let present = Set(library.allSessions().compactMap(\.title))
        var loaded = 0

        for url in archives.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let title = url.deletingPathExtension().lastPathComponent
            guard !present.contains(title) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let archive = try? SessionArchive.decode(data)
            else { continue }

            // `upToDateSession` rather than the stored one: a seed built
            // before an analysis-version bump would otherwise show stale
            // numbers, and stale numbers are exactly what this set exists to
            // catch.
            library.save(archive.upToDateSession())
            loaded += 1
        }

        if loaded > 0 {
            print("[DevSeed] loaded \(loaded) test session(s) from the bundle")
        }
    }
}
#endif
