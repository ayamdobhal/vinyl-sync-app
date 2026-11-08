import Foundation

// Rank only recording candidates supplied by the resolver; never infer that a
// track belongs to an album solely because that album was playing previously.
enum SpotifyAlbumPreference {
  static func key(title: String, artist: String) -> String {
    func normalize(_ text: String) -> String {
      text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
    return normalize(artist) + "|" + normalize(title)
  }

  static func select(_ candidates: [[String: Any]], preferredAlbumID: String,
                     ownedAlbums: Set<String>) -> [String: Any]? {
    let playable = candidates.filter { ($0["is_playable"] as? Bool) != false }
    if !preferredAlbumID.isEmpty,
       let previous = playable.first(where: {
         ($0["album"] as? [String: Any])?["id"] as? String == preferredAlbumID
       }) { return previous }
    if let owned = playable.first(where: { track in
      let album = track["album"] as? [String: Any] ?? [:]
      let artists = ((album["artists"] as? [[String: Any]]) ?? [])
        .compactMap { $0["name"] as? String }.joined(separator: ", ")
      return ownedAlbums.contains(key(title: album["name"] as? String ?? "", artist: artists))
    }) { return owned }
    return playable.first
  }
}
