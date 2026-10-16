// TASK 4 - Dual-Dashboard Service App (Ride / Delivery) with Live Map Tracking
//
// pubspec.yaml dependencies:
//   geolocator: ^13.0.2
//   flutter_map: ^7.0.2
//   latlong2: ^0.9.1
//   flutter_local_notifications: ^17.2.4
//
// --- ANDROID SETUP --------------------------------------------------------
// 1) android/app/src/main/AndroidManifest.xml (inside <manifest>, above <application>):
//      <uses-permission android:name="android.permission.INTERNET"/>
//      <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
//      <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
//      <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
// 2) android/app/build.gradle (needed by flutter_local_notifications):
//      android { compileOptions { coreLibraryDesugaringEnabled true } }
//      dependencies { coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4' }
//    (In build.gradle.kts:  isCoreLibraryDesugaringEnabled = true  and
//     coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4"))
//
// --- iOS SETUP ------------------------------------------------------------
//   ios/Runner/Info.plist -> add NSLocationWhenInUseUsageDescription
//
// MAP: uses OpenStreetMap tiles (no API key needed). To use Mapbox instead,
// replace the TileLayer urlTemplate with your Mapbox raster-tiles URL + token.
//
// HOW THE DEMO WORKS (single device, mock backend in memory):
//   Customer: tap map to pick destination -> request booking.
//   Provider: accept -> provider marker drives to pickup (live tracking),
//             "Start trip" -> drives to destination -> customer checks out.
//   Use the swap icon in the app bar to switch dashboards.

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

// ---------------------------------------------------------------------------
// GLOBALS
// ---------------------------------------------------------------------------
final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

const LatLng kDemoLocation = LatLng(37.4219, -122.0840);

final AppState app = AppState();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  runApp(const DualDashboardApp());
}

// ---------------------------------------------------------------------------
// NOTIFICATIONS
// ---------------------------------------------------------------------------
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _id = 0;

  static Future<void> init() async {
    if (kIsWeb) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      );
      await _plugin.initialize(settings);
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  static Future<void> show(String title, String body) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        _id++,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'ride_updates',
            'Booking updates',
            channelDescription: 'Status updates for your bookings',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// MODELS
// ---------------------------------------------------------------------------
enum ServiceType { ride, delivery }

extension ServiceTypeX on ServiceType {
  String get label => this == ServiceType.ride ? 'Ride' : 'Delivery';
  IconData get icon =>
      this == ServiceType.ride ? Icons.directions_car : Icons.delivery_dining;
}

enum BookingStatus {
  requested,
  accepted,
  arrived,
  inProgress,
  completed,
  paid,
  cancelled
}

String money(double v) => '\$${v.toStringAsFixed(2)}';

double kmBetween(LatLng a, LatLng b) =>
    const Distance().as(LengthUnit.Kilometer, a, b);

class Booking {
  Booking({
    required this.id,
    required this.type,
    required this.pickup,
    required this.destination,
    required this.distanceKm,
  });

  final String id;
  final ServiceType type;
  final LatLng pickup;
  final LatLng destination;
  final double distanceKm;

  BookingStatus status = BookingStatus.requested;
  String? paymentMethod;
  bool paying = false;

  double get baseFare => type == ServiceType.ride ? 2.5 : 1.5;
  double get perKm => type == ServiceType.ride ? 1.2 : 0.9;
  double get distanceFare => distanceKm * perKm;
  double get tax => (baseFare + distanceFare) * 0.05;
  double get total => baseFare + distanceFare + tax;
}

// ---------------------------------------------------------------------------
// APP STATE (shared mock backend for both dashboards)
// ---------------------------------------------------------------------------
class AppState extends ChangeNotifier {
  LatLng? myPos;
  String? locationError;
  StreamSubscription<Position>? _sub;
  bool _locating = false;

  Booking? booking;
  LatLng? providerPos;
  Timer? _timer;

  bool providerOnline = true;
  double earnings = 0;
  final List<Booking> history = [];

  // ---- live location ------------------------------------------------------
  Future<void> startLocation() async {
    if (_sub != null || _locating) return;
    _locating = true;
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        locationError = 'Location services are turned off.';
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        locationError = 'Location permission was denied.';
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        locationError =
            'Location permission is permanently denied. Enable it in app settings.';
        return;
      }

      final first = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      myPos = LatLng(first.latitude, first.longitude);
      locationError = null;

      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((p) {
        myPos = LatLng(p.latitude, p.longitude);
        notifyListeners();
      });
    } catch (e) {
      locationError = 'Could not get your location.';
    } finally {
      _locating = false;
      notifyListeners();
    }
  }

  void useDemoLocation() {
    myPos = kDemoLocation;
    locationError = null;
    notifyListeners();
  }

  // ---- notifications (system + in-app banner) -----------------------------
  void notify(String title, String body) {
    NotificationService.show(title, body);
    messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(body),
            ],
          ),
        ),
      );
  }

  // ---- customer actions ---------------------------------------------------
  void requestBooking(ServiceType type, LatLng destination) {
    final pickup = myPos;
    if (pickup == null) return;
    booking = Booking(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: type,
      pickup: pickup,
      destination: destination,
      distanceKm: kmBetween(pickup, destination),
    );
    providerPos = null;
    if (providerOnline) {
      notify('New ${type.label.toLowerCase()} request',
          'A customer is requesting a ${type.label.toLowerCase()} nearby.');
    }
    notifyListeners();
  }

  void cancelBooking() {
    final b = booking;
    if (b == null) return;
    if (b.status == BookingStatus.requested ||
        b.status == BookingStatus.accepted) {
      b.status = BookingStatus.cancelled;
      _timer?.cancel();
      providerPos = null;
      notify('Booking cancelled', 'The booking was cancelled.');
      notifyListeners();
    }
  }

  void clearBooking() {
    _timer?.cancel();
    booking = null;
    providerPos = null;
    notifyListeners();
  }

  // ---- provider actions ---------------------------------------------------
  void setProviderOnline(bool value) {
    providerOnline = value;
    notifyListeners();
  }

  void acceptBooking() {
    final b = booking;
    if (b == null || b.status != BookingStatus.requested) return;
    b.status = BookingStatus.accepted;
    providerPos =
        LatLng(b.pickup.latitude + 0.01, b.pickup.longitude + 0.01);
    _startSimulation();
    notify('Provider accepted',
        'Your ${b.type.label.toLowerCase()} is on the way.');
    notifyListeners();
  }

  void declineBooking() {
    final b = booking;
    if (b == null || b.status != BookingStatus.requested) return;
    b.status = BookingStatus.cancelled;
    notify('Request declined', 'No provider is available right now.');
    notifyListeners();
  }

  void startTrip() {
    final b = booking;
    if (b == null || b.status != BookingStatus.arrived) return;
    b.status = BookingStatus.inProgress;
    _startSimulation();
    notify('Trip started', 'Your ${b.type.label.toLowerCase()} has started.');
    notifyListeners();
  }

  // ---- checkout -----------------------------------------------------------
  Future<void> pay(String method) async {
    final b = booking;
    if (b == null || b.status != BookingStatus.completed || b.paying) return;
    b.paying = true;
    b.paymentMethod = method;
    notifyListeners();

    await Future.delayed(const Duration(seconds: 2)); // fake payment gateway

    b.paying = false;
    b.status = BookingStatus.paid;
    earnings += b.total;
    history.insert(0, b);
    notify('Payment received', '${money(b.total)} paid via $method.');
    notifyListeners();
  }

  // ---- simulated provider movement (live tracking demo) -------------------
  void _startSimulation() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final b = booking;
    final current = providerPos;
    if (b == null || current == null) {
      _timer?.cancel();
      return;
    }

    LatLng? target;
    if (b.status == BookingStatus.accepted) {
      target = b.pickup;
    } else if (b.status == BookingStatus.inProgress) {
      target = b.destination;
    }
    if (target == null) {
      _timer?.cancel();
      return;
    }

    if (kmBetween(current, target) < 0.03) {
      providerPos = target;
      _timer?.cancel();
      if (b.status == BookingStatus.accepted) {
        b.status = BookingStatus.arrived;
        notify('Provider arrived', 'Your provider is at the pickup point.');
      } else {
        b.status = BookingStatus.completed;
        notify('Trip completed',
            'Please complete payment of ${money(b.total)}.');
      }
    } else {
      providerPos = LatLng(
        current.latitude + (target.latitude - current.latitude) * 0.2,
        current.longitude + (target.longitude - current.longitude) * 0.2,
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// APP ROOT
// ---------------------------------------------------------------------------
class DualDashboardApp extends StatelessWidget {
  const DualDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dual Dashboard',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepOrange),
      home: const RoleScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// ROLE SELECTION
// ---------------------------------------------------------------------------
class RoleScreen extends StatelessWidget {
  const RoleScreen({super.key});

  Widget _card(BuildContext context, IconData icon, String title,
      String subtitle, Widget screen) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => screen)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              CircleAvatar(radius: 28, child: Icon(icon, size: 30)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(subtitle),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.local_taxi, size: 72),
                  const SizedBox(height: 12),
                  Text(
                    'QuickGo',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text('Choose your dashboard',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 28),
                  _card(context, Icons.person, 'Customer',
                      'Book a ride or delivery and track it live',
                      const CustomerScreen()),
                  const SizedBox(height: 12),
                  _card(context, Icons.badge, 'Service Provider',
                      'Accept jobs, navigate and earn',
                      const ProviderScreen()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SHARED WIDGETS
// ---------------------------------------------------------------------------
Marker pin(LatLng p, IconData icon, Color color) => Marker(
      point: p,
      width: 44,
      height: 44,
      child: Icon(icon, color: color, size: 36),
    );

class LiveMap extends StatefulWidget {
  const LiveMap({
    super.key,
    required this.center,
    required this.markers,
    this.onTap,
  });

  final LatLng center;
  final List<Marker> markers;
  final void Function(LatLng point)? onTap;

  @override
  State<LiveMap> createState() => _LiveMapState();
}

class _LiveMapState extends State<LiveMap> {
  final MapController _controller = MapController();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: widget.center,
            initialZoom: 15,
            onTap: widget.onTap == null
                ? null
                : (tapPosition, point) => widget.onTap!(point),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.dual_dashboard',
            ),
            MarkerLayer(markers: widget.markers),
          ],
        ),
        Positioned(
          right: 12,
          top: 12,
          child: FloatingActionButton.small(
            heroTag: null,
            onPressed: () {
              try {
                _controller.move(widget.center, 15);
              } catch (_) {}
            },
            child: const Icon(Icons.my_location),
          ),
        ),
      ],
    );
  }
}

/// Waits for a location fix (or lets the user pick a demo location).
class LocationGate extends StatelessWidget {
  const LocationGate({super.key, required this.builder});
  final Widget Function(LatLng pos) builder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final pos = app.myPos;
        if (pos != null) return builder(pos);

        if (app.locationError == null) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Getting your location...'),
              ],
            ),
          );
        }

        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.location_off, size: 56),
                const SizedBox(height: 12),
                Text(app.locationError!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: app.startLocation,
                  child: const Text('Try again'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: app.useDemoLocation,
                  child: const Text('Use demo location'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class BottomPanel extends StatelessWidget {
  const BottomPanel({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 10,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CUSTOMER DASHBOARD
// ---------------------------------------------------------------------------
class CustomerScreen extends StatefulWidget {
  const CustomerScreen({super.key});

  @override
  State<CustomerScreen> createState() => _CustomerScreenState();
}

class _CustomerScreenState extends State<CustomerScreen> {
  ServiceType _type = ServiceType.ride;
  LatLng? _dest;

  @override
  void initState() {
    super.initState();
    app.startLocation();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customer Dashboard')),
      body: LocationGate(
        builder: (pos) {
          final b = app.booking;
          final markers = <Marker>[];
          if (b == null) {
            markers.add(pin(pos, Icons.person_pin_circle, Colors.blue));
            if (_dest != null) markers.add(pin(_dest!, Icons.flag, Colors.red));
          } else {
            markers.add(pin(b.pickup, Icons.person_pin_circle, Colors.blue));
            markers.add(pin(b.destination, Icons.flag, Colors.red));
            if (app.providerPos != null &&
                b.status != BookingStatus.cancelled &&
                b.status != BookingStatus.paid) {
              markers.add(pin(app.providerPos!, b.type.icon, Colors.green));
            }
          }

          return Column(
            children: [
              Expanded(
                child: LiveMap(
                  key: ValueKey(b?.id ?? 'new'),
                  center: b?.pickup ?? pos,
                  markers: markers,
                  onTap: b == null ? (p) => setState(() => _dest = p) : null,
                ),
              ),
              _buildPanel(context, pos, b),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPanel(BuildContext context, LatLng pos, Booking? b) {
    final titleStyle = Theme.of(context)
        .textTheme
        .titleMedium
        ?.copyWith(fontWeight: FontWeight.bold);

    if (b == null) {
      Booking? preview;
      if (_dest != null) {
        preview = Booking(
          id: 'preview',
          type: _type,
          pickup: pos,
          destination: _dest!,
          distanceKm: kmBetween(pos, _dest!),
        );
      }
      final tooClose = preview != null && preview.distanceKm < 0.05;

      return BottomPanel(
        children: [
          SegmentedButton<ServiceType>(
            segments: ServiceType.values
                .map((t) => ButtonSegment<ServiceType>(
                      value: t,
                      label: Text(t.label),
                      icon: Icon(t.icon),
                    ))
                .toList(),
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          const SizedBox(height: 12),
          if (preview == null)
            const Text('Tap anywhere on the map to set your destination.')
          else if (tooClose)
            const Text('Please pick a destination a bit farther away.')
          else
            Text(
              '${preview.distanceKm.toStringAsFixed(2)} km  -  estimated ${money(preview.total)}',
              style: titleStyle,
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: (preview == null || tooClose)
                ? null
                : () => app.requestBooking(_type, _dest!),
            icon: const Icon(Icons.check_circle_outline),
            label: Text('Request ${_type.label}'),
          ),
        ],
      );
    }

    switch (b.status) {
      case BookingStatus.requested:
        return BottomPanel(children: [
          Text('Looking for a provider...', style: titleStyle),
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: app.cancelBooking,
            child: const Text('Cancel booking'),
          ),
        ]);

      case BookingStatus.accepted:
        final d = app.providerPos == null
            ? 0.0
            : kmBetween(app.providerPos!, b.pickup);
        return BottomPanel(children: [
          Text('Provider is on the way', style: titleStyle),
          const SizedBox(height: 4),
          Text('${d.toStringAsFixed(2)} km away'),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: app.cancelBooking,
            child: const Text('Cancel booking'),
          ),
        ]);

      case BookingStatus.arrived:
        return BottomPanel(children: [
          Text('Your provider has arrived', style: titleStyle),
          const SizedBox(height: 4),
          const Text('The trip will start shortly.'),
        ]);

      case BookingStatus.inProgress:
        final d = app.providerPos == null
            ? 0.0
            : kmBetween(app.providerPos!, b.destination);
        return BottomPanel(children: [
          Text('Trip in progress', style: titleStyle),
          const SizedBox(height: 4),
          Text('${d.toStringAsFixed(2)} km to destination'),
        ]);

      case BookingStatus.completed:
        return BottomPanel(children: [
          Text('Trip completed - ${money(b.total)} due', style: titleStyle),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CheckoutScreen()),
            ),
            icon: const Icon(Icons.payment),
            label: const Text('Proceed to checkout'),
          ),
        ]);

      case BookingStatus.paid:
        return BottomPanel(children: [
          Text('Paid ${money(b.total)}. Thank you!', style: titleStyle),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              app.clearBooking();
              setState(() => _dest = null);
            },
            child: const Text('Done'),
          ),
        ]);

      case BookingStatus.cancelled:
        return BottomPanel(children: [
          Text('Booking cancelled', style: titleStyle),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              app.clearBooking();
              setState(() => _dest = null);
            },
            child: const Text('New booking'),
          ),
        ]);
    }
  }
}

// ---------------------------------------------------------------------------
// CHECKOUT (transaction state flow)
// ---------------------------------------------------------------------------
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  static const List<String> _methods = ['Cash', 'Credit/Debit Card', 'Wallet'];
  String _method = _methods.first;

  Widget _row(String label, String value, {bool bold = false}) {
    final style = bold
        ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label, style: style), Text(value, style: style)],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final b = app.booking;

        if (b == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Checkout')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('This booking is closed.'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Back'),
                  ),
                ],
              ),
            ),
          );
        }

        if (b.status == BookingStatus.paid) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Receipt'),
              automaticallyImplyLeading: false,
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.check_circle,
                          color: Colors.green, size: 80),
                      const SizedBox(height: 12),
                      Text(
                        'Payment successful',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 20),
                      _row('Service', b.type.label),
                      _row('Distance', '${b.distanceKm.toStringAsFixed(2)} km'),
                      _row('Paid via', b.paymentMethod ?? '-'),
                      const Divider(),
                      _row('Total', money(b.total), bold: true),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: () {
                          app.clearBooking();
                          Navigator.of(context).pop();
                        },
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(title: const Text('Checkout')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text('Order summary',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  _row('Service', b.type.label),
                  _row('Distance', '${b.distanceKm.toStringAsFixed(2)} km'),
                  _row('Base fare', money(b.baseFare)),
                  _row('Distance fare', money(b.distanceFare)),
                  _row('Tax (5%)', money(b.tax)),
                  const Divider(),
                  _row('Total', money(b.total), bold: true),
                  const SizedBox(height: 24),
                  Text('Payment method',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _methods
                        .map((m) => ChoiceChip(
                              label: Text(m),
                              selected: _method == m,
                              onSelected: b.paying
                                  ? null
                                  : (_) => setState(() => _method = m),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: b.paying ? null : () => app.pay(_method),
                    icon: b.paying
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock),
                    label: Text(
                      b.paying ? 'Processing...' : 'Pay ${money(b.total)}',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// SERVICE PROVIDER DASHBOARD
// ---------------------------------------------------------------------------
class ProviderScreen extends StatefulWidget {
  const ProviderScreen({super.key});

  @override
  State<ProviderScreen> createState() => _ProviderScreenState();
}

class _ProviderScreenState extends State<ProviderScreen> {
  @override
  void initState() {
    super.initState();
    app.startLocation();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Provider Dashboard')),
      body: LocationGate(
        builder: (pos) {
          final b = app.booking;
          final showJob = b != null &&
              b.status != BookingStatus.cancelled &&
              (b.status != BookingStatus.requested || app.providerOnline);

          final markers = <Marker>[];
          if (showJob) {
            markers.add(pin(b.pickup, Icons.person_pin_circle, Colors.blue));
            markers.add(pin(b.destination, Icons.flag, Colors.red));
            if (app.providerPos != null && b.status != BookingStatus.paid) {
              markers.add(pin(app.providerPos!, b.type.icon, Colors.green));
            }
          } else {
            markers.add(pin(pos, Icons.my_location, Colors.green));
          }

          return Column(
            children: [
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Switch(
                        value: app.providerOnline,
                        onChanged: app.setProviderOnline,
                      ),
                      Text(app.providerOnline ? 'Online' : 'Offline'),
                      const Spacer(),
                      Text(
                        'Earnings: ${money(app.earnings)}  (${app.history.length} jobs)',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: LiveMap(
                  key: ValueKey(showJob ? b.id : 'idle'),
                  center: showJob ? b.pickup : pos,
                  markers: markers,
                ),
              ),
              _buildPanel(context, b),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPanel(BuildContext context, Booking? b) {
    final titleStyle = Theme.of(context)
        .textTheme
        .titleMedium
        ?.copyWith(fontWeight: FontWeight.bold);

    if (b == null) {
      return BottomPanel(children: [
        Text(
          app.providerOnline ? 'Waiting for requests...' : 'You are offline',
          style: titleStyle,
        ),
        if (app.providerOnline) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
      ]);
    }

    switch (b.status) {
      case BookingStatus.requested:
        if (!app.providerOnline) {
          return BottomPanel(children: [
            Text('Go online to see incoming requests', style: titleStyle),
          ]);
        }
        return BottomPanel(children: [
          Row(
            children: [
              Icon(b.type.icon),
              const SizedBox(width: 8),
              Text('New ${b.type.label.toLowerCase()} request',
                  style: titleStyle),
            ],
          ),
          const SizedBox(height: 6),
          Text(
              '${b.distanceKm.toStringAsFixed(2)} km trip  -  you earn ${money(b.total)}'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: app.declineBooking,
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: app.acceptBooking,
                  child: const Text('Accept'),
                ),
              ),
            ],
          ),
        ]);

      case BookingStatus.accepted:
        final d = app.providerPos == null
            ? 0.0
            : kmBetween(app.providerPos!, b.pickup);
        return BottomPanel(children: [
          Text('Heading to pickup', style: titleStyle),
          const SizedBox(height: 4),
          Text('${d.toStringAsFixed(2)} km remaining'),
        ]);

      case BookingStatus.arrived:
        return BottomPanel(children: [
          Text('You have arrived at pickup', style: titleStyle),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: app.startTrip,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start trip'),
          ),
        ]);

      case BookingStatus.inProgress:
        final d = app.providerPos == null
            ? 0.0
            : kmBetween(app.providerPos!, b.destination);
        return BottomPanel(children: [
          Text('Trip in progress', style: titleStyle),
          const SizedBox(height: 4),
          Text('${d.toStringAsFixed(2)} km to destination'),
        ]);

      case BookingStatus.completed:
        return BottomPanel(children: [
          Text('Trip completed', style: titleStyle),
          const SizedBox(height: 4),
          Text('Waiting for customer to pay ${money(b.total)}...'),
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ]);

      case BookingStatus.paid:
        return BottomPanel(children: [
          Text('Payment received: ${money(b.total)}', style: titleStyle),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: app.clearBooking,
            child: const Text('Ready for next job'),
          ),
        ]);

      case BookingStatus.cancelled:
        return BottomPanel(children: [
          Text('Booking cancelled', style: titleStyle),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: app.clearBooking,
            child: const Text('OK'),
          ),
        ]);
    }
  }
}
