import 'dart:async';
import 'dart:convert';

import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

/// The Bitcoin orange used for BTC Map markers.
const Color _bitcoinOrange = Color(0xFFF7931A);

/// Keyless OpenStreetMap-derived vector style, the same source BTC Map's own
/// apps use. Safe to use in distributed apps (unlike the OSMF tile servers),
/// and renders cross-platform (incl. Linux) because vector_map_tiles is pure
/// Dart.
///
/// `positron` is the lightest OpenFreeMap style (few layers), which keeps the
/// CPU-side vector rendering fast and lets the orange markers stand out. The
/// heavier `liberty`/`bright` styles look richer but render noticeably slower.
const String _styleUrl = 'https://tiles.openfreemap.org/styles/positron';

/// Minimum zoom level at which we query and render places. Below this the map
/// covers too large an area to fetch or display markers usefully.
const double _minFetchZoom = 9;

/// Cap the search radius so a single request never tries to pull in an
/// unreasonable number of places.
const double _maxRadiusKm = 100;

/// Cap the number of markers rendered at once to keep the map responsive.
const int _maxMarkers = 500;

/// Zoom level to center on when we have the user's location — close enough that
/// nearby places load immediately, without the user having to zoom in.
const double _seededZoom = 13;

/// A place that accepts Bitcoin, as returned by the BTC Map v4 API.
class BtcMapPlace {
  final int id;
  final double lat;
  final double lon;
  final String? name;
  final String? address;
  final String? openingHours;
  final String? phone;
  final String? website;

  const BtcMapPlace({
    required this.id,
    required this.lat,
    required this.lon,
    this.name,
    this.address,
    this.openingHours,
    this.phone,
    this.website,
  });

  /// True when there are extra details worth showing beyond the name.
  bool get hasDetails =>
      address != null ||
      openingHours != null ||
      phone != null ||
      website != null;

  static BtcMapPlace? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final lat = json['lat'];
    final lon = json['lon'];
    if (id is! int || lat is! num || lon is! num) {
      return null;
    }
    String? str(String key) {
      final value = json[key];
      return (value is String && value.trim().isNotEmpty) ? value.trim() : null;
    }

    return BtcMapPlace(
      id: id,
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      name: str('name'),
      address: str('address'),
      openingHours: str('opening_hours'),
      phone: str('phone'),
      website: str('website'),
    );
  }
}

/// Fetches places that accept Bitcoin near a coordinate from the BTC Map API.
Future<List<BtcMapPlace>> _searchPlaces({
  required double lat,
  required double lon,
  required double radiusKm,
}) async {
  final uri = Uri.parse('https://api.btcmap.org/v4/places/search/').replace(
    queryParameters: {
      'lat': lat.toString(),
      'lon': lon.toString(),
      'radius_km': radiusKm.toStringAsFixed(2),
      'fields': 'id,lat,lon,name,address,opening_hours,phone,website',
    },
  );

  final response = await http
      .get(uri, headers: {'User-Agent': 'org.fedimint.app'}) // i18n-ignore
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('BTC Map API returned ${response.statusCode}');
  }

  final decoded = jsonDecode(response.body);
  if (decoded is! List) {
    return const [];
  }
  return decoded
      .whereType<Map<String, dynamic>>()
      .map(BtcMapPlace.fromJson)
      .whereType<BtcMapPlace>()
      .toList(growable: false);
}

/// A pannable map of places that accept Bitcoin, rendered with flutter_map and
/// keyless OpenFreeMap vector tiles, backed by BTC Map data.
class BtcMapScreen extends StatefulWidget {
  const BtcMapScreen({super.key});

  @override
  State<BtcMapScreen> createState() => _BtcMapScreenState();
}

class _BtcMapScreenState extends State<BtcMapScreen> {
  final MapController _mapController = MapController();
  Timer? _debounce;
  bool _mapReady = false;
  bool _loading = false;
  bool _locating = false;
  bool _zoomTooLow = true;
  List<BtcMapPlace> _places = const [];

  /// The loaded vector style, or null while loading. [_styleError] is set if
  /// loading failed.
  Style? _style;
  bool _styleError = false;

  /// Monotonically increasing id used to discard responses for searches that
  /// have been superseded by a more recent map movement.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _loadStyle();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadStyle() async {
    setState(() => _styleError = false);
    try {
      final style = await StyleReader(uri: _styleUrl).read();
      if (!mounted) return;
      setState(() => _style = style);
    } catch (_) {
      if (!mounted) return;
      setState(() => _styleError = true);
    }
  }

  void _onMapReady() {
    _mapReady = true;
    _fetchVisible();
    // Offer to center on the user's location. This prompts for permission the
    // first time; if declined or unavailable, the world view is kept.
    _locateUser();
  }

  /// Centers the map on the user's location if permission is granted. When
  /// [manual] (the location button), shows a toast if the location can't be
  /// determined; the initial automatic attempt fails silently.
  Future<void> _locateUser({bool manual = false}) async {
    if (_locating) return;
    setState(() => _locating = true);
    final location = await _currentLocation();
    if (!mounted) return;
    setState(() => _locating = false);
    if (location != null) {
      if (_mapReady) _mapController.move(location, _seededZoom);
    } else if (manual) {
      ToastService().show(
        message: context.l10n.btcMapLocationUnavailable,
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: const Icon(Icons.location_off),
      );
    }
  }

  /// Resolves the device's current location, requesting permission if needed.
  /// Returns null if location services are off, permission is denied, or the
  /// platform can't provide a fix.
  Future<LatLng?> _currentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      Position? position;
      try {
        position = await Geolocator.getLastKnownPosition();
      } catch (_) {
        position = null;
      }
      position ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return LatLng(position.latitude, position.longitude);
    } catch (_) {
      return null;
    }
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _fetchVisible);
  }

  Future<void> _fetchVisible() async {
    if (!_mapReady || !mounted) return;
    final camera = _mapController.camera;

    if (camera.zoom < _minFetchZoom) {
      setState(() {
        _zoomTooLow = true;
        _loading = false;
        _places = const [];
      });
      return;
    }

    final center = camera.center;
    final radiusKm = (const Distance().as(
              LengthUnit.Meter,
              center,
              camera.visibleBounds.northEast,
            ) /
            1000)
        .clamp(0.5, _maxRadiusKm);

    final requestId = ++_requestId;
    setState(() {
      _zoomTooLow = false;
      _loading = true;
    });

    try {
      final places = await _searchPlaces(
        lat: center.latitude,
        lon: center.longitude,
        radiusKm: radiusKm.toDouble(),
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _places = places.take(_maxMarkers).toList(growable: false);
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() => _loading = false);
      ToastService().show(
        message: context.l10n.btcMapLoadError,
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: const Icon(Icons.error_outline),
      );
    }
  }

  void _showPlaceSheet(BtcMapPlace place) {
    final theme = Theme.of(context);
    final name = place.name?.trim();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.bottomSheetTheme.backgroundColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Colors.grey[700],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      const _BtcMapMarker(size: 30),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          name == null || name.isEmpty
                              ? sheetContext.l10n.btcMapUnnamedPlace
                              : name,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (place.hasDetails) ...[
                    const SizedBox(height: 16),
                    if (place.address != null)
                      CopyableDetailRow(
                        label: sheetContext.l10n.btcMapAddress,
                        value: place.address!,
                      ),
                    if (place.openingHours != null)
                      CopyableDetailRow(
                        label: sheetContext.l10n.btcMapHours,
                        value: place.openingHours!,
                        showCopyButton: false,
                      ),
                    if (place.phone != null)
                      CopyableDetailRow(
                        label: sheetContext.l10n.btcMapPhone,
                        value: place.phone!,
                      ),
                    if (place.website != null)
                      CopyableDetailRow(
                        label: sheetContext.l10n.btcMapWebsite,
                        value: place.website!,
                        additionalAction: IconButton(
                          iconSize: 20,
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          tooltip: sheetContext.l10n.btcMapOpenWebsite,
                          icon: Icon(
                            Icons.open_in_new,
                            color: theme.colorScheme.primary,
                          ),
                          onPressed: () => _openUrl(place.website!),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  List<Marker> _buildMarkers() {
    return _places
        .map(
          (place) => Marker(
            point: LatLng(place.lat, place.lon),
            width: 36,
            height: 36,
            child: GestureDetector(
              onTap: () => _showPlaceSheet(place),
              child: const _BtcMapMarker(),
            ),
          ),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final mapVisible = _style != null && !_styleError;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.btcMapTitle)),
      body: _buildBody(context),
      floatingActionButton:
          mapVisible
              ? FloatingActionButton.small(
                onPressed: _locating ? null : () => _locateUser(manual: true),
                tooltip: context.l10n.btcMapMyLocation,
                child:
                    _locating
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.my_location),
              )
              : null,
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_styleError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined, size: 48),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                context.l10n.btcMapLoadError,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadStyle,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.btcMapRetry),
            ),
          ],
        ),
      );
    }

    final style = _style;
    if (style == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: const LatLng(20, 0),
            initialZoom: 3,
            minZoom: 2,
            maxZoom: 18,
            onMapReady: _onMapReady,
            onPositionChanged: _onPositionChanged,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            VectorTileLayer(
              theme: style.theme,
              sprites: style.sprites,
              tileProviders: style.providers,
              maximumZoom: 18,
            ),
            MarkerLayer(markers: _buildMarkers()),
          ],
        ),
        if (_zoomTooLow) _HintBanner(text: context.l10n.btcMapZoomInHint),
        if (_loading)
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 6),
                ],
              ),
              child: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
      ],
    );
  }
}

/// A circular Bitcoin-orange map pin.
class _BtcMapMarker extends StatelessWidget {
  final double size;
  const _BtcMapMarker({this.size = 36});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _bitcoinOrange,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Icon(
        Icons.currency_bitcoin,
        color: Colors.white,
        size: size * 0.6,
      ),
    );
  }
}

/// A floating hint shown over the map when the user is zoomed out too far to
/// load places.
class _HintBanner extends StatelessWidget {
  final String text;
  const _HintBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      top: 16,
      left: 16,
      right: 16,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.zoom_in, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Flexible(child: Text(text, style: theme.textTheme.bodyMedium)),
            ],
          ),
        ),
      ),
    );
  }
}
