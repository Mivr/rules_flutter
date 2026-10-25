import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ios_greeting_plugin/ios_greeting_plugin.dart';

void main() {
  runApp(const CounterApp());
}

/// Root widget of the iOS integration test example app.
class CounterApp extends StatelessWidget {
  /// Creates the counter application widget.
  const CounterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Integration iOS Counter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const CounterHomePage(),
    );
  }
}

/// Counter screen displaying the tap count, bundled asset, and Swift-reported bundle id.
class CounterHomePage extends StatefulWidget {
  /// Creates the counter home page.
  const CounterHomePage({super.key});

  @override
  State<CounterHomePage> createState() => _CounterHomePageState();
}

class _CounterHomePageState extends State<CounterHomePage> {
  int _counter = 0;
  String _bundleId = 'Loading...';

  @override
  void initState() {
    super.initState();
    unawaited(_loadBundleId());
  }

  Future<void> _loadBundleId() async {
    final bundleId = await const IosGreetingPlugin().getAppBundleId();
    if (!mounted) {
      return;
    }
    setState(() {
      _bundleId = bundleId ?? 'Unknown bundle id';
    });
  }

  void _increment() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Integration iOS Counter')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Image.asset(
              'assets/logo.png',
              key: const ValueKey<String>('app_logo'),
            ),
            Text(
              _bundleId,
              key: const ValueKey<String>('plugin_bundle_id'),
            ),
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              key: const ValueKey<String>('counter_text'),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey<String>('increment_button'),
        onPressed: _increment,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
