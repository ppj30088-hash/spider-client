// The managed-mode preset: one switch per online service, compiled into
// sing-box route rules in the shared global pool.
//
// Where the table comes from
// ---------------------------
// AIsouler/MyClash's mihomoScript.js ships `ruleOptionsEnable` (the service
// switches) and `serviceConfigs` (one rule set per service). Its rule sets are
// mihomo `.mrs` files, which this app cannot load: ConfigGenerator.collectRuleSets
// (ConfigGenerator.kt:287-308) accepts only an http(s) URL whose file name
// contains `.srs`, or a bare srslist catalog name resolved through
// `routing.catalog.urlOf(name)` — an unknown name fails the whole config build.
// So a service here names *candidate* srslist entries, and the page resolves them
// against the installed catalog (`routes.ruleSets`) before writing anything.
// A candidate that resolves to nothing is skipped; the inline domain lists are
// the fallback that still makes the switch mean something on a bare catalog.
//
// The wire shape
// --------------
// The pool is written through `saveGlobalRules`, and `ruleRowFromWire`
// (route_actions.go:648-652) stores every `<column>_json` value by marshalling
// it. A JSON *list* therefore lands as `["a","b"]` and reads back through
// `jsonList`; a pre-encoded *string* would be marshalled again and read back as
// an empty list. So `_json` values are real lists here, never jsonEncode output.
// Only column-shaped names are used: the editor's shorthand (`rule_set`,
// `domain_suffix`) is stored by the kernel but never echoed by `wireRules`, so a
// rule written with it would be invisible — and rewritable — as empty.
//
// Idempotency
// -----------
// Every row this file produces carries a `managed:` name prefix. The page reads
// the pool, drops those rows, appends this build, and writes the pool back, so
// toggling switches any number of times never duplicates a row and never touches
// a rule the user wrote by hand.

/// The outbound ids the routing layer uses (OutboundIds.kt): a route to -1 goes
/// through the proxy, -2 is direct, and -3 is the block outbound behind a reject.
const int managedProxyOutbound = -1;
const int managedDirectOutbound = -2;
const int managedRejectOutbound = -3;

/// The name prefix that marks a row as this screen's own. `stripManagedRules`
/// and the page's read-spread-write both key on it.
const String managedRulePrefix = 'managed:';

/// One service row: identity for the UI, the catalog names to resolve, the
/// inline lists to fall back on, and where matching traffic goes.
class ManagedService {
  const ManagedService({
    required this.id,
    required this.name,
    required this.emoji,
    this.defaultEnabled = true,
    this.ruleSetNames = const <String>[],
    this.domainSuffixes = const <String>[],
    this.domainKeywords = const <String>[],
    this.domains = const <String>[],
    this.outbound = managedProxyOutbound,
    this.action = 'route',
  });

  /// Stable across releases; the preference map and the row names key on it.
  final String id;

  /// The service name as the reference app shows it (a brand name, not a
  /// translated string).
  final String name;

  /// The app ships no brand glyphs, so a service is marked by an emoji.
  final String emoji;

  final bool defaultEnabled;

  /// Candidate srslist catalog entries, in preference order. Resolution keeps
  /// every candidate that has an exact catalog entry, which is how a service
  /// with both a domain set and an IP set keeps both.
  final List<String> ruleSetNames;

  final List<String> domainSuffixes;
  final List<String> domainKeywords;
  final List<String> domains;

  /// See [managedProxyOutbound] and friends.
  final int outbound;

  /// `route` or `reject`; a reject row carries [managedRejectOutbound].
  final String action;

  bool get rejects => action == 'reject';

  bool get hasInlineConditions =>
      domainSuffixes.isNotEmpty || domainKeywords.isNotEmpty || domains.isNotEmpty;
}

/// The reference script's `ruleOptionsEnable`, in the order it lists them, minus
/// the four selection strategies (手动选择 / 自动选择 / 负载均衡 / 故障转移):
/// those are proxy-group policies, not services, and this app's groups already
/// own them.
const List<ManagedService> managedServices = <ManagedService>[
  ManagedService(id: 'fcm', name: 'FCM', emoji: '📨', ruleSetNames: ['geosite-googlefcm'], outbound: managedDirectOutbound),
  ManagedService(id: 'youtube', name: 'YouTube', emoji: '▶️', ruleSetNames: ['geosite-youtube']),
  ManagedService(id: 'google', name: 'Google', emoji: '🔍', ruleSetNames: ['geosite-google', 'geoip-google']),
  ManagedService(
    id: 'ai', name: 'AI', emoji: '🤖',
    ruleSetNames: ['geosite-category-ai-!cn'],
    // The reference adds these three by hand: the AI chat UIs that load their
    // assets from separate analytics hosts.
    domainSuffixes: ['cdn.usefathom.com', 'intercom.io', 'intercomcdn.com'],
  ),
  ManagedService(id: 'github', name: 'GitHub', emoji: '🐙', ruleSetNames: ['geosite-github', 'geoip-github']),
  ManagedService(id: 'microsoft', name: 'Microsoft', emoji: '🪟', ruleSetNames: ['geosite-microsoft', 'geoip-microsoft']),
  ManagedService(id: 'apple', name: 'Apple', emoji: '🍎', ruleSetNames: ['geosite-apple']),
  ManagedService(id: 'telegram', name: 'Telegram', emoji: '✈️', ruleSetNames: ['geosite-telegram', 'geoip-telegram']),
  ManagedService(id: 'steam', name: 'Steam', emoji: '🎮', ruleSetNames: ['geosite-steam']),
  ManagedService(id: 'tiktok', name: 'TikTok', emoji: '🎵', ruleSetNames: ['geosite-tiktok']),
  ManagedService(id: 'twitter', name: 'Twitter', emoji: '🐦', ruleSetNames: ['geosite-twitter', 'geoip-twitter']),
  ManagedService(id: 'meta', name: 'Meta', emoji: '📘', ruleSetNames: ['geosite-meta', 'geoip-facebook']),
  ManagedService(id: 'line', name: 'Line', emoji: '💬', ruleSetNames: ['geosite-line']),
  ManagedService(id: 'netflix', name: 'Netflix', emoji: '🎬', ruleSetNames: ['geosite-netflix', 'geoip-netflix']),
  ManagedService(
    id: 'emby', name: 'Emby', emoji: '📺',
    ruleSetNames: ['geosite-category-emby'],
    domainSuffixes: ['mb3admin.com', 'nubebelle.com'],
    domainKeywords: ['emby'],
  ),
  ManagedService(id: 'pikpak', name: 'PikPak', emoji: '📦', ruleSetNames: ['geosite-pikpak']),
  ManagedService(id: 'spotify', name: 'Spotify', emoji: '🎧', ruleSetNames: ['geosite-spotify']),
  ManagedService(id: 'crypto', name: 'Crypto', emoji: '🪙', ruleSetNames: ['geosite-category-cryptocurrency']),
  ManagedService(id: 'paypal', name: 'PayPal', emoji: '💳', ruleSetNames: ['geosite-paypal']),
  ManagedService(id: 'patreon', name: 'Patreon', emoji: '🎗️', ruleSetNames: ['geosite-patreon']),
  ManagedService(id: 'ehentai', name: 'EHentai', emoji: '🔞', ruleSetNames: ['geosite-ehentai']),
  ManagedService(
    id: 'adblock', name: 'AdBlock', emoji: '🚫',
    ruleSetNames: ['geosite-category-ads'],
    outbound: managedRejectOutbound,
    action: 'reject',
  ),
];

/// The reference script's `prefixRules`: always on, evaluated before every
/// service, and expressed with srslist names too so nothing unresolvable reaches
/// the kernel. Kept out of the list above because no switch turns them off.
const List<ManagedService> managedBaseRules = <ManagedService>[
  ManagedService(id: 'base-private', name: 'Private', emoji: '🏠',
    ruleSetNames: ['geosite-private', 'geoip-private'], outbound: managedDirectOutbound),
  ManagedService(id: 'base-cn', name: 'Mainland China', emoji: '🇨🇳',
    ruleSetNames: ['geosite-geolocation-cn', 'geoip-cn'],
    domainSuffixes: ['fsend.cn'], outbound: managedDirectOutbound),
  ManagedService(id: 'base-games-cn', name: 'China games', emoji: '🕹️',
    ruleSetNames: ['geosite-category-games@cn'], outbound: managedDirectOutbound),
  ManagedService(id: 'base-synology-cn', name: 'Synology', emoji: '🗄️',
    ruleSetNames: ['geosite-synology@cn'], outbound: managedDirectOutbound),
  ManagedService(id: 'base-nvidia-cn', name: 'NVIDIA', emoji: '🖥️',
    ruleSetNames: ['geosite-nvidia@cn'],
    domainSuffixes: ['international-gfe.download.nvidia.com'],
    domainKeywords: ['ctaiot.com'], outbound: managedDirectOutbound),
  ManagedService(id: 'base-apple-cn', name: 'Apple China', emoji: '🍏',
    ruleSetNames: ['geosite-apple@cn'], outbound: managedDirectOutbound),
  ManagedService(id: 'base-microsoft-cn', name: 'Microsoft China', emoji: '🪟',
    ruleSetNames: ['geosite-microsoft@cn'], outbound: managedDirectOutbound),
];

/// The reference's outside-China catch-all, kept *after* the services.
///
/// The pool is first-match-wins, and `geolocation-!cn` answers for nearly every
/// host these services name: put ahead of them it would swallow the AdBlock
/// reject and the FCM direct row, so every switch would look like it did
/// nothing. It is the last word instead — everything off-shore that no service
/// claimed still goes through the proxy.
const List<ManagedService> managedFallbackRules = <ManagedService>[
  ManagedService(id: 'base-!cn', name: 'Rest of the world', emoji: '🌍',
    ruleSetNames: ['geosite-geolocation-!cn'], outbound: managedProxyOutbound),
];

/// The complete default switch state: the table's own defaults.
Map<String, bool> defaultManagedServices() => {
  for (final service in managedServices) service.id: service.defaultEnabled,
};

/// The service list in [order]: every id it names first, in that order, then the
/// rest in the table's order. Ids the table no longer has are dropped, which is
/// what makes a stored order survive a table change.
List<ManagedService> managedServiceOrder(List<String> order) {
  final byId = {for (final service in managedServices) service.id: service};
  final seen = <String>{};
  return [
    for (final id in order)
      if (byId[id] != null && seen.add(id)) byId[id]!,
    for (final service in managedServices)
      if (!seen.contains(service.id)) service,
  ];
}

/// True when [name] is one of this screen's rows.
bool isManagedRuleName(String name) => name.startsWith(managedRulePrefix);

/// The wire rules for every enabled service, between the always-on base rules
/// and the outside-China catch-all.
///
/// [enabled] maps a service id to its switch; a missing id falls back to the
/// table's default. [resolvedNames] maps a candidate catalog name to the exact
/// catalog entry it resolved to (`routes.ruleSets` answered with that name), and
/// a candidate missing from it is skipped rather than written blind.
///
/// [order] is the service order the page keeps: the pool is checked top to
/// bottom and the first match wins, so this is the order the switches mean. Ids
/// it does not name keep the table's order after the ones it does.
///
/// The result is ready for `saveGlobalRules`: only `_json` column names, values
/// as lists, no editor shorthand.
List<Map<String, dynamic>> buildManagedRules({
  required Map<String, bool> enabled,
  required Map<String, String> resolvedNames,
  List<String> order = const <String>[],
}) => [
  for (final rule in managedBaseRules) ..._rowsOf(rule, resolvedNames),
  for (final service in _orderedServices(order))
    if (enabled[service.id] ?? service.defaultEnabled) ..._rowsOf(service, resolvedNames),
  for (final rule in managedFallbackRules) ..._rowsOf(rule, resolvedNames),
];

/// [managedServices] with the ids [order] names first, in that order.
List<ManagedService> _orderedServices(List<String> order) =>
    order.isEmpty ? managedServices : managedServiceOrder(order);

/// [rules] minus every managed row, in the same order: the user's own pool
/// entries survive a managed apply untouched.
List<Map<String, dynamic>> stripManagedRules(List<Map<String, dynamic>> rules) => [
  for (final rule in rules)
    if (!isManagedRuleName('${rule['name'] ?? ''}')) rule,
];

/// One service's rows: the rule-set row first (it carries the bulk of the
/// matching), then the inline one. Both are ordinary custom rules, so the pool
/// list and the editor render them like any other.
List<Map<String, dynamic>> _rowsOf(ManagedService service, Map<String, String> resolvedNames) {
  final markers = <Map<String, dynamic>>[];
  final ruleSets = <String>[];
  for (final candidate in service.ruleSetNames) {
    final exact = resolvedNames[candidate];
    if (exact != null && exact.isNotEmpty && !ruleSets.contains(exact)) ruleSets.add(exact);
  }
  if (ruleSets.isNotEmpty) markers.add({'rule_set_json': ruleSets});
  if (service.hasInlineConditions) {
    markers.add({
      if (service.domains.isNotEmpty) 'domain_json': service.domains,
      if (service.domainSuffixes.isNotEmpty) 'domain_suffix_json': service.domainSuffixes,
      if (service.domainKeywords.isNotEmpty) 'domain_keyword_json': service.domainKeywords,
    });
  }
  return [
    for (var index = 0; index < markers.length; index++)
      <String, dynamic>{
        'name': '$managedRulePrefix${service.id}:$index',
        'type': 'custom',
        'action': service.action,
        'outbound_id': service.outbound,
        'disabled': false,
        ...markers[index],
      },
  ];
}

// --- URL safety --------------------------------------------------------------

/// True when [url] is a rule-set URL this app may hand to the kernel: an http(s)
/// address with a host that is not local, loopback, private, link-local,
/// CGNAT, ULA or otherwise reserved.
///
/// The catalog is the host's own data, so nothing here is fetched from Dart —
/// the check exists because a rule-set URL is also a download the core performs,
/// and a catalog entry pointing at a LAN address is a mistake worth refusing.
bool isSafeRuleSetUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  if (uri.userInfo.isNotEmpty) return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) return false;
  final literal = parseAddressLiteral(host);
  if (literal != null) return !isReservedAddress(literal);
  // A name that is not a literal is fine: the core resolves it and a private
  // answer is its own business, not a static check here.
  return true;
}

/// The IPv4/IPv6 bytes of [host] when it is a literal, else null. Covers the
/// `a.b.c.d`, `::1`, `fc00::1` and `::ffff:1.2.3.4` forms.
List<int>? parseAddressLiteral(String host) {
  var text = host.trim().toLowerCase();
  if (text.startsWith('[') && text.endsWith(']')) text = text.substring(1, text.length - 1);
  final v4 = _parseV4(text);
  if (v4 != null) return v4;
  if (!text.contains(':')) return null;
  return _parseV6(text);
}

List<int>? _parseV4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final bytes = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return null;
    if (part.length > 1 && part.startsWith('0')) return null; // no octal-looking parts
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    bytes.add(value);
  }
  return bytes;
}

/// Eight 16-bit groups from an RFC 4291 textual form, or null when the text is
/// not an address. The last group may be a dotted IPv4 tail (`::ffff:1.2.3.4`).
List<int>? _parseV6(String host) {
  final halves = host.split('::');
  if (halves.length > 2) return null;
  final head = halves[0].isEmpty ? <String>[] : halves[0].split(':');
  final tail = halves.length == 2 ? (halves[1].isEmpty ? <String>[] : halves[1].split(':')) : <String>[];
  final groups = <int>[];

  int? valueOf(String group, {bool allowV4 = false}) {
    if (group.isEmpty) return null;
    if (allowV4 && group.contains('.')) {
      final v4 = _parseV4(group);
      if (v4 == null) return null;
      return (v4[0] << 8) | v4[1];
    }
    if (group.length > 4) return null;
    return int.tryParse(group, radix: 16);
  }

  final headValues = <int>[];
  for (var i = 0; i < head.length; i++) {
    final value = valueOf(head[i], allowV4: head.length - 1 == i && halves.length == 1);
    if (value == null) return null;
    headValues.add(value);
    if (head[i].contains('.')) {
      final v4 = _parseV4(head[i]);
      if (v4 == null) return null;
      headValues[headValues.length - 1] = (v4[0] << 8) | v4[1];
      headValues.add((v4[2] << 8) | v4[3]);
    }
  }
  final tailValues = <int>[];
  for (var i = 0; i < tail.length; i++) {
    final value = valueOf(tail[i], allowV4: tail.length - 1 == i);
    if (value == null) return null;
    tailValues.add(value);
    if (tail[i].contains('.')) {
      final v4 = _parseV4(tail[i]);
      if (v4 == null) return null;
      tailValues[tailValues.length - 1] = (v4[0] << 8) | v4[1];
      tailValues.add((v4[2] << 8) | v4[3]);
    }
  }
  groups.addAll(headValues);
  if (halves.length == 2) {
    final fill = 8 - headValues.length - tailValues.length;
    if (fill < 0) return null;
    groups.addAll(List<int>.filled(fill, 0));
  }
  groups.addAll(tailValues);
  if (groups.length != 8) return null;
  if (groups.any((group) => group < 0 || group > 0xffff)) return null;
  return [
    for (final group in groups) ...[group >> 8, group & 0xff],
  ];
}

/// True for every address block a rule-set download must not point at: the
/// ranges RFC 1918/6598/6890/5737/4193 reserves for local and documentation use.
bool isReservedAddress(List<int> bytes) {
  if (bytes.length == 4) {
    final a = bytes[0], b = bytes[1];
    if (a == 0) return true; // "this network"
    if (a == 10) return true; // private
    if (a == 127) return true; // loopback
    if (a == 169 && b == 254) return true; // link-local
    if (a == 172 && b >= 16 && b <= 31) return true; // private
    if (a == 192 && b == 168) return true; // private
    if (a == 192 && b == 0 && bytes[2] == 0) return true; // IETF protocol assignments
    if (a == 192 && b == 0 && bytes[2] == 2) return true; // TEST-NET-1
    if (a == 192 && b == 88 && bytes[2] == 99) return true; // 6to4 relay anycast
    if (a == 198 && (b == 18 || b == 19)) return true; // benchmarking
    if (a == 198 && b == 51 && bytes[2] == 100) return true; // TEST-NET-2
    if (a == 203 && b == 0 && bytes[2] == 113) return true; // TEST-NET-3
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT
    if (a >= 224) return true; // multicast and reserved
    return false;
  }
  if (bytes.length == 16) {
    final allZero = bytes.every((byte) => byte == 0);
    if (allZero) return true; // unspecified
    final loopback = bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
    if (loopback) return true; // ::1
    if ((bytes[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique local
    if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return true; // fe80::/10 link-local
    if (bytes[0] == 0xff) return true; // multicast
    // ::ffff:a.b.c.d (IPv4-mapped) takes the IPv4 verdict.
    if (bytes.take(10).every((byte) => byte == 0) && bytes[10] == 0xff && bytes[11] == 0xff) {
      return isReservedAddress(bytes.sublist(12));
    }
    return false;
  }
  return true;
}
