import 'package:flutter/material.dart';

/// Global route observer enabling route awareness (e.g. RouteAware, didPopNext)
/// across the application.
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();
