import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'l10n/app_localizations.dart';

/// One open-source component, with the licence it ships under.
///
/// The authoritative, complete list is whatever `showLicensePage` renders from
/// `LicenseRegistry` — this is a human-readable summary of the pieces that do
/// the actual work, not a substitute for it.
class _Component {
  final String name;
  final String license;
  final String role;
  const _Component(this.name, this.license, this.role);
}

const _components = <_Component>[
  _Component('pitch_detector_dart', 'BSD 3-Clause',
      'YIN pitch detection, after Alain de Cheveigné & Hideki Kawahara (2002)'),
  _Component('fftea', 'Apache-2.0', 'Fast Fourier transform for the spectrum display'),
  _Component('onnx_runtime_dart', 'MIT',
      'Pure-Dart model inference for the transcription mode'),
  _Component('Basic Pitch (model weights)', 'Apache-2.0',
      'Polyphonic note transcription, after Gfeller et al. (Spotify, ICASSP 2022)'),
  _Component('record', 'BSD 3-Clause', 'Microphone capture on mobile and desktop'),
  _Component('flutter_pcm_sound', 'Unlicense', 'Low-latency PCM playback for reference tones'),
  _Component('shared_preferences', 'BSD 3-Clause', 'Stores your concert pitch and instrument'),
  _Component('collection', 'BSD 3-Clause', 'Queue and equality helpers'),
  _Component('Flutter', 'BSD 3-Clause', 'Application framework'),
];

const _repoUrl = 'https://github.com/CrispStrobe/flutter_tuner';
const _privacyUrl = 'https://crisptuner.vercel.app/privacy.html';

/// Registers licences that `showLicensePage` cannot discover on its own.
///
/// Flutter collects licences from pub packages automatically, but nothing
/// registers the application's own licence, so CrispTuner would be the one
/// thing missing from its own licence page.
void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['CrispTuner'],
      '''MIT License

Copyright (c) 2026 Christian Ströbele

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''',
    );
    // Academic attribution for the algorithm itself — the pub package's own
    // BSD licence covers the code, not the citation.
    yield const LicenseEntryWithLineBreaks(
      ['YIN pitch detection algorithm'],
      '''CrispTuner detects pitch with the YIN algorithm:

  A. de Cheveigné and H. Kawahara, "YIN, a fundamental frequency estimator
  for speech and music", Journal of the Acoustical Society of America,
  111 (4), pp. 1917-1930, 2002.

The implementation used is the `pitch_detector_dart` package, which is
distributed under the BSD 3-Clause License.''',
    );
  });
}

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  static const _gitHash = String.fromEnvironment('GIT_HASH', defaultValue: 'dev');
  static const _buildDate = String.fromEnvironment('BUILD_DATE', defaultValue: 'local');

  String _version = '…';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = '${info.version}+${info.buildNumber}');
    }).catchError((_) {
      // Version is cosmetic; a failure here must not break the screen.
      if (mounted) setState(() => _version = 'unknown');
    });
  }

  void _copy(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _header(context, l10n),
          _section(Icons.business, l10n.aboutServiceProvider, const SelectableText(
            'Christian Ströbele\n'
            'Nikolausstr. 5\n'
            '70190 Stuttgart\n'
            'Germany\n\n'
            'postmaster@crispstro.be',
          )),
          _section(Icons.copyright, l10n.aboutLicense, Text(l10n.aboutLicenseBody)),
          _section(Icons.graphic_eq, l10n.aboutHowItWorks, Text(l10n.aboutHowItWorksBody)),
          _section(Icons.inventory_2_outlined, l10n.aboutComponents, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.aboutComponentsIntro,
                  style: const TextStyle(fontSize: 12, height: 1.4)),
              const SizedBox(height: 12),
              for (final c in _components) ...[
                _ComponentRow(c),
                if (c != _components.last) const SizedBox(height: 10),
              ],
            ],
          )),
          _section(Icons.shield_outlined, l10n.aboutPrivacy, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.aboutPrivacyBody),
              const SizedBox(height: 10),
              _LinkText(
                label: l10n.aboutPrivacyPolicyLink,
                url: _privacyUrl,
                onTap: () => _copy(_privacyUrl, l10n.aboutCopied),
              ),
            ],
          )),
          _section(Icons.gavel, l10n.aboutDisclaimer, Text(l10n.aboutDisclaimerBody)),
          _section(Icons.code, l10n.aboutSourceCode, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LinkText(
                label: _repoUrl,
                url: _repoUrl,
                onTap: () => _copy(_repoUrl, l10n.aboutCopied),
              ),
              const SizedBox(height: 8),
              Text(l10n.aboutContributions, style: const TextStyle(fontSize: 12)),
            ],
          )),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            icon: const Icon(Icons.description_outlined),
            label: Text(l10n.aboutOpenSourceLicenses),
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'CrispTuner',
              applicationVersion: '$_version ($_gitHash)',
              applicationLegalese: 'MIT License — © 2026 Christian Ströbele',
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, AppLocalizations l10n) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.music_note, size: 28,
                  color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CrispTuner', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  SelectableText('v$_version ($_gitHash) · $_buildDate',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 4),
                  Text(l10n.aboutTagline,
                      style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _section(IconData icon, String title, Widget child) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title, style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
              ),
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _ComponentRow extends StatelessWidget {
  final _Component component;
  const _ComponentRow(this.component);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text(component.name, style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13)),
            Text(component.license, style: TextStyle(
                fontSize: 10, color: Theme.of(context).colorScheme.primary)),
          ],
        ),
        const SizedBox(height: 2),
        Text(component.role, style: const TextStyle(fontSize: 12, height: 1.35)),
      ],
    );
  }
}

/// A tappable URL. There is no `url_launcher` dependency — and adding one just
/// to open two links would pull native code into an app that otherwise makes no
/// outside calls — so tapping copies the address instead.
class _LinkText extends StatelessWidget {
  final String label;
  final String url;
  final VoidCallback onTap;
  const _LinkText({required this.label, required this.url, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      label: '$label. $url',
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
