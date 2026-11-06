import 'package:even_companion/services/walknav/nav_geo.dart';

/// Pulls a destination out of what Google Maps shares.
///
/// Google Maps' "Share" sends text such as `Place name\nAddress\n
/// https://maps.app.goo.gl/AbC123`. The short link has no coordinates; the
/// caller resolves its redirects and hands the final URL back to
/// [coordinatesFromUrl]. Expanded links carry the place pin as
/// `!3d<lat>!4d<lon>`, which is preferred over the `@lat,lon` viewport centre.
class MapsShare {
  static final _urlPattern = RegExp(r'https?://\S+');
  static final _pin = RegExp(r'!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)');
  static final _pair = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$');
  static final _at = RegExp(r'@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)');
  // Directions links encode each stop as !1d<lon>!2d<lat> - longitude first.
  static final _stop = RegExp(r'!1d(-?\d+(?:\.\d+)?)!2d(-?\d+(?:\.\d+)?)');

  /// First URL in shared text, or null.
  static String? firstUrl(String text) {
    final m = _urlPattern.firstMatch(text);
    if (m == null) return null;
    return m.group(0)!.replaceAll(RegExp(r'[)\].,;]+$'), '');
  }

  /// A plain `lat,lon` anywhere in the shared text (e.g. a dropped pin).
  static LatLon? coordinatesFromText(String text) {
    for (final line in text.split('\n')) {
      final m = _pair.firstMatch(line);
      if (m != null) return _valid(m.group(1)!, m.group(2)!);
    }
    return null;
  }

  /// Short links need resolving before they yield coordinates.
  static bool needsResolving(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == 'maps.app.goo.gl' || host == 'goo.gl';
  }

  /// Destination coordinates from an expanded Google Maps URL, or null.
  static LatLon? coordinatesFromUrl(String url) {
    var u = Uri.tryParse(url);
    if (u == null) return null;
    // EU consent interstitial wraps the real URL.
    if (u.host.startsWith('consent.') &&
        u.queryParameters['continue'] != null) {
      u = Uri.tryParse(u.queryParameters['continue']!);
      if (u == null) return null;
    }
    final full = Uri.decodeFull(u.toString());

    // A shared route: the last stop is the destination.
    final stops = _stop.allMatches(full).toList();
    if (u.path.contains('/dir/') && stops.isNotEmpty) {
      final m = stops.last;
      return _valid(m.group(2)!, m.group(1)!);
    }
    final pin = _pin.allMatches(full).toList();
    if (pin.isNotEmpty) {
      // Directions links list every stop; the last pin is the destination.
      final m = pin.last;
      return _valid(m.group(1)!, m.group(2)!);
    }
    for (final key in const ['destination', 'daddr', 'q', 'query', 'll']) {
      final v = u.queryParameters[key];
      if (v == null) continue;
      final m = _pair.firstMatch(v);
      if (m != null) return _valid(m.group(1)!, m.group(2)!);
    }
    // /maps/dir/<a>/<b>/ with coordinate segments: take the last one.
    LatLon? lastSegment;
    for (final seg in u.pathSegments) {
      final m = _pair.firstMatch(seg);
      if (m != null) lastSegment = _valid(m.group(1)!, m.group(2)!);
    }
    if (lastSegment != null) return lastSegment;
    final at = _at.firstMatch(full);
    if (at != null) return _valid(at.group(1)!, at.group(2)!);
    return null;
  }

  static LatLon? _valid(String a, String b) {
    final lat = double.tryParse(a);
    final lon = double.tryParse(b);
    if (lat == null || lon == null) return null;
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return LatLon(lat, lon);
  }
}
