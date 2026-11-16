import '../widgets.dart';

/// The exit countries the helpers can be asked for: the country codes
/// Psiphon publishes as egress regions, which are also the realistic
/// Cloudflare exit countries for Aether's --exit-loc filter. An empty code
/// means "any country" — the helper picks the fastest route it finds.
class HelperCountry {
  const HelperCountry(this.code, this.name);
  final String code;
  final String name;
}

const helperCountries = <HelperCountry>[
  HelperCountry('AT', 'Austria'),
  HelperCountry('AU', 'Australia'),
  HelperCountry('BE', 'Belgium'),
  HelperCountry('BG', 'Bulgaria'),
  HelperCountry('CA', 'Canada'),
  HelperCountry('CH', 'Switzerland'),
  HelperCountry('CZ', 'Czechia'),
  HelperCountry('DE', 'Germany'),
  HelperCountry('DK', 'Denmark'),
  HelperCountry('EE', 'Estonia'),
  HelperCountry('ES', 'Spain'),
  HelperCountry('FI', 'Finland'),
  HelperCountry('FR', 'France'),
  HelperCountry('GB', 'United Kingdom'),
  HelperCountry('HR', 'Croatia'),
  HelperCountry('HU', 'Hungary'),
  HelperCountry('IE', 'Ireland'),
  HelperCountry('IN', 'India'),
  HelperCountry('IT', 'Italy'),
  HelperCountry('JP', 'Japan'),
  HelperCountry('LV', 'Latvia'),
  HelperCountry('NL', 'Netherlands'),
  HelperCountry('NO', 'Norway'),
  HelperCountry('PL', 'Poland'),
  HelperCountry('PT', 'Portugal'),
  HelperCountry('RO', 'Romania'),
  HelperCountry('RS', 'Serbia'),
  HelperCountry('SE', 'Sweden'),
  HelperCountry('SG', 'Singapore'),
  HelperCountry('SK', 'Slovakia'),
  HelperCountry('US', 'United States'),
];

String helperCountryName(String code) {
  for (final country in helperCountries) {
    if (country.code == code) return country.name;
  }
  return code;
}

/// A country picker row for the helper cards, built on the app's own
/// [ListItem.options] (its popup menu, not Material's PopupMenuButton,
/// which expands to fill its parent here). The current choice reads
/// "Fastest" for any country. [onSelected] receives the two-letter code,
/// or "" for any country. The row has no extra padding: the card already
/// pads its content.
class HelperCountryPicker extends StatelessWidget {
  const HelperCountryPicker({
    super.key,
    required this.value,
    required this.onSelected,
    this.enabled = true,
  });

  final String value;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final picker = ListItem<String>.options(
      padding: EdgeInsets.zero,
      title: Text(context.tr('Exit country')),
      options: ['', for (final country in helperCountries) country.code],
      value: value,
      textBuilder: (code) =>
          code.isEmpty ? context.tr('Fastest') : helperCountryName(code),
      onChanged: onSelected,
    );
    if (enabled) return picker;
    // No enabled flag on the row itself: block taps and dim it while the
    // card is busy (a connect or rescan is already running).
    return IgnorePointer(
      ignoring: true,
      child: Opacity(opacity: 0.5, child: picker),
    );
  }
}
