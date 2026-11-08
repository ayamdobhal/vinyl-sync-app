import Foundation

@main
struct SpotifyAlbumPreferenceTests {
  static func main() {
    func track(_ album: String, _ title: String, _ artist: String = "Radiohead", playable: Bool = true) -> [String: Any] {
      ["uri": "spotify:track:\(album)", "is_playable": playable,
       "album": ["id": album, "name": title, "artists": [["name": artist]]]]
    }
    let single = track("single", "High & Dry / Planet Telex")
    let album = track("album", "The Bends")
    let owned: Set<String> = [SpotifyAlbumPreference.key(title: "The Bends", artist: "Radiohead")]
    func selected(_ candidates: [[String: Any]], _ previous: String = "", _ keys: Set<String> = []) -> String? {
      SpotifyAlbumPreference.select(candidates, preferredAlbumID: previous, ownedAlbums: keys)?["uri"] as? String
    }
    assert(selected([single, album], "album") == "spotify:track:album")
    assert(selected([single, album], "", owned) == "spotify:track:album")
    assert(selected([single], "album", owned) == "spotify:track:single", "Never invent album membership")
    assert(selected([single, track("other", "The Bends", "Other Artist")], "", owned) == "spotify:track:single")
    assert(selected([single, track("album", "The Bends", playable: false)], "album", owned) == "spotify:track:single")
    assert(selected([single, album]) == "spotify:track:single")
    assert(selected([]) == nil)
    print("Spotify album preference regression checks passed")
  }
}
