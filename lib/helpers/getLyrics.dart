import 'dart:convert';
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart';
import 'package:http/http.dart' as http;
import 'package:spotube/helpers/get-random-element.dart';
import 'package:spotube/models/Logger.dart';
import 'package:spotube/models/generated_secrets.dart';
import 'package:collection/collection.dart';

final logger = getLogger("GetLyrics");

String clearArtistsOfTitle(String title, List<String> artists) {
  return title
      .replaceAll(RegExp(artists.join("|"), caseSensitive: false), "")
      .trim();
}

String getTitle(
  String title, {
  List<String> artists = const [],
  bool onlyCleanArtist = false,
}) {
  final match = RegExp(r"(?<=\().+?(?=\))").firstMatch(title)?.group(0);
  final artistInBracket =
      artists.any((artist) => match?.contains(artist) ?? false);

  if (artistInBracket) {
    title = title.replaceAll(
      RegExp(" *\\([^)]*\\) *"),
      '',
    );
  }

  title = clearArtistsOfTitle(title, artists);
  if (onlyCleanArtist) {
    artists = [];
  }

  return "$title ${artists.map((e) => e.replaceAll(",", " ")).join(", ")}"
      .toLowerCase()
      .replaceAll(RegExp(" *\\[[^\\]]*]"), '')
      .replaceAll(RegExp("feat.|ft."), '')
      .replaceAll(RegExp("\\s+"), ' ')
      .trim();
}

Future<String?> extractLyrics(Uri url) async {
  try {
    var response = await http.get(url);

    Document document = parser.parse(response.body);
    var lyrics = document.querySelector('div.lyrics')?.text.trim();
    if (lyrics == null) {
      lyrics = "";
      document
          .querySelectorAll("div[class^=\"Lyrics__Container\"]")
          .forEach((element) {
        if (element.text.trim().isNotEmpty) {
          var snippet = element.innerHtml.replaceAll("<br>", "\n").replaceAll(
                RegExp("<(?!\\s*br\\s*\\/?)[^>]+>", caseSensitive: false),
                "",
              );
          var el = document.createElement("textarea");
          el.innerHtml = snippet;
          lyrics = "$lyrics${el.text.trim()}\n\n";
        }
      });
    }

    return lyrics;
  } catch (e, stack) {
    logger.e("extractLyrics", e, stack);
    rethrow;
  }
}

Future<List?> searchSong(
  String title,
  List<String> artist, {
  String? apiKey,
  bool optimizeQuery = false,
  bool authHeader = false,
}) async {
  try {
    if (apiKey == "" || apiKey == null) {
      apiKey = getRandomElement(lyricsSecrets);
    }
    const searchUrl = 'https://api.genius.com/search?q=';
    String song =
        optimizeQuery ? getTitle(title, artists: artist) : "$title $artist";

    String reqUrl = "$searchUrl${Uri.encodeComponent(song)}";
    Map<String, String> headers = {"Authorization": 'Bearer $apiKey'};
    final response = await http.get(
      Uri.parse(authHeader ? reqUrl : "$reqUrl&access_token=$apiKey"),
      headers: authHeader ? headers : null,
    );
    Map data = jsonDecode(response.body)["response"];
    if (data["hits"]?.length == 0) return null;
    List results = data["hits"]?.map((val) {
      return <String, dynamic>{
        "id": val["result"]["id"],
        "full_title": val["result"]["full_title"],
        "albumArt": val["result"]["song_art_image_url"],
        "url": val["result"]["url"],
        "author": val["result"]["primary_artist"]["name"],
      };
    }).toList();
    return results;
  } catch (e, stack) {
    logger.e("searchSong", e, stack);
    rethrow;
  }
}

Future<String?> getLyrics(
  String title,
  List<String> artists, {
  required String apiKey,
  bool optimizeQuery = false,
  bool authHeader = false,
}) async {
  try {
    final results = await searchSong(
      title,
      artists,
      apiKey: apiKey,
      optimizeQuery: optimizeQuery,
      authHeader: authHeader,
    );
    if (results == null) return null;
    title = getTitle(
      title,
      artists: artists,
      onlyCleanArtist: true,
    ).trim();
    final ratedLyrics = results.map((result) {
      final gTitle = (result["full_title"] as String).toLowerCase();
      int points = 0;
      final hasTitle = gTitle.contains(title);
      final hasAllArtists =
          artists.every((artist) => gTitle.contains(artist.toLowerCase()));
      final String lyricAuthor = result["author"].toLowerCase();
      final fromOriginalAuthor =
          lyricAuthor.contains(artists.first.toLowerCase());

      for (final criteria in [
        hasTitle,
        hasAllArtists,
        fromOriginalAuthor,
      ]) {
        if (criteria) points++;
      }
      return {"result": result, "points": points};
    }).sorted(
      (a, b) => ((a["points"] as int).compareTo(a["points"] as int)),
    );
    final worthyOne = ratedLyrics.first["result"];

    String? lyrics = await extractLyrics(Uri.parse(worthyOne["url"]));
    return lyrics;
  } catch (e, stack) {
    logger.e("getLyrics", e, stack);
    return null;
  }
}
