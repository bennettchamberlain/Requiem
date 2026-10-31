import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:scoria_api_client/scoria_api_client.dart';
import 'package:scoria_app/chat/voice_cubit.dart';
import 'package:scoria_app/config/chat_settings_cubit.dart';
import 'package:scoria_app/ui/chrome.dart';
import 'package:scoria_models/scoria_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// One Connect catalog. Each row starts OAuth for that connector.
class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> with WidgetsBindingObserver {
  ChatCatalog? _catalog;
  String? _error;
  var _loading = true;
  var _busy = false;
  var _query = '';
  var _category = 'all';

  MaiaApiClient get _api => context.read<MaiaApiClient>();

  ChatConnection? get _one => _catalog?.connections.cast<ChatConnection?>().firstWhere(
        (c) => c?.id == 'one',
        orElse: () => null,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalog = await _api.chatTools();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _loading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String? _absolute(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    final parsed = Uri.parse(path);
    final resolved = _api.baseUrl.resolve(
      parsed.path.startsWith('/') ? parsed.path.substring(1) : parsed.path,
    );
    return resolved.replace(
      queryParameters: {
        ...resolved.queryParameters,
        ...parsed.queryParameters,
      },
      fragment: parsed.hasFragment ? parsed.fragment : null,
    ).toString();
  }

  Future<void> _openOauth(String? url) async {
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _connect(String platform) async {
    setState(() => _busy = true);
    try {
      final result = await _api.oneAccount(platform, syncing: true);
      if (!mounted) return;
      if (result.isOauth) {
        await _openOauth(_absolute(result.authorizeUrl));
        setState(() => _busy = false);
        return;
      }
      if (result.isUnconfigured) {
        setState(() => _busy = false);
        ShadToaster.of(context).show(
          ShadToast.destructive(
            title: const Text('One'),
            description: Text(
              result.message ??
                  'The Linux box needs ONE_CLIENT_ID and ONE_CONNECT_KEY.',
            ),
          ),
        );
        return;
      }
      await _load();
      if (!mounted) return;
      setState(() => _busy = false);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ShadToaster.of(context).show(
        ShadToast.destructive(
          title: const Text('Connect'),
          description: Text('$e'),
        ),
      );
    }
  }

  Future<void> _disconnect(String platform) async {
    setState(() => _busy = true);
    try {
      await _api.oneAccount(platform, syncing: false);
      await _load();
    } on Exception catch (e) {
      if (!mounted) return;
      ShadToaster.of(context).show(
        ShadToast.destructive(
          title: const Text('Disconnect'),
          description: Text('$e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync(String platform) async {
    setState(() => _busy = true);
    try {
      await _api.oneSync(platforms: [platform]);
      if (!mounted) return;
      ShadToaster.of(context).show(
        ShadToast(
          title: const Text('Sync queued'),
          description: Text(platform),
        ),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ShadToaster.of(context).show(
        ShadToast.destructive(
          title: const Text('Sync'),
          description: Text('$e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setYouKey() async {
    final key = await showShadDialog<String>(
      context: context,
      builder: (_) => const _YouKeyDialog(),
    );
    if (key == null || key.isEmpty) return;
    setState(() => _busy = true);
    try {
      final catalog = await _api.putConnection('you', apiKey: key);
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _busy = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ShadToaster.of(context).show(
        ShadToast.destructive(title: const Text('You.com'), description: Text('$e')),
      );
    }
  }

  OneAccount? _accountFor(_Connector item) {
    final accounts = _one?.accounts ?? const <OneAccount>[];
    for (final account in accounts) {
      if (account.platform == item.slug) return account;
    }
    return null;
  }

  bool _connected(_Connector item) {
    if (_accountFor(item) != null) return true;
    return _one?.platforms.contains(item.slug) ?? false;
  }

  _Connector _connectorFor(OneAccount account) {
    for (final item in _connectors) {
      if (item.slug == account.platform) return item;
    }
    return _Connector(
      account.platform,
      account.label,
      'all',
      'Granted through One.',
      LucideIcons.link,
      const Color(0xFF111111),
    );
  }

  List<_Connector> get _visible {
    final q = _query.trim().toLowerCase();
    return [
      for (final item in _connectors)
        if ((_category == 'all' || item.category == _category) &&
            (q.isEmpty ||
                item.title.toLowerCase().contains(q) ||
                item.slug.contains(q)))
          item,
    ];
  }

  int get _connectedCount => _one?.accounts.length ?? 0;

  String get _connectedLabel {
    final n = _connectedCount;
    if (n == 1) return '1 account connected';
    return '$n accounts connected';
  }

  void _openDetail(_Connector item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ConnectorDetail(
          item: item,
          account: _accountFor(item),
          connected: _connected(item),
          busy: _busy,
          onConnect: () => _connect(item.slug),
          onDisconnect: () => _disconnect(item.slug),
          onSync: () => _sync(item.slug),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Scaffold(
      body: Column(
        children: [
          MaiaHeader(
            title: 'Connectors',
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(_connectedLabel, style: theme.textTheme.small),
              ),
              ShadIconButton.ghost(
                key: const Key('tools_refresh_button'),
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                onPressed: _busy ? null : _load,
              ),
            ],
          ),
          Expanded(
            child: _loading && _catalog == null
                ? const MaiaSkeleton()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      if (_error != null) ...[
                        ShadAlert.destructive(
                          title: const Text('Could not load connectors'),
                          description: Text(_error!),
                        ),
                        const SizedBox(height: 12),
                      ],
                      ShadInput(
                        placeholder: const Text('Search apps'),
                        leading: const Icon(LucideIcons.search, size: 16),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final chip in _categories) ...[
                              _CategoryChip(
                                label: chip.$2,
                                selected: _category == chip.$1,
                                onPressed: () =>
                                    setState(() => _category = chip.$1),
                              ),
                              const SizedBox(width: 8),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(_connectedLabel, style: theme.textTheme.h4),
                      const SizedBox(height: 4),
                      Text(
                        'One keeps the login. Maia stores the grant and '
                        'pulls each account into memory.',
                        style: theme.textTheme.muted,
                      ),
                      const SizedBox(height: 20),
                      if (_query.isEmpty &&
                          _category == 'all' &&
                          _connectedCount > 0) ...[
                        _SectionLabel('Connected'),
                        const SizedBox(height: 8),
                        for (final account in _one!.accounts)
                          _ConnectorRow(
                            item: _connectorFor(account),
                            connected: true,
                            busy: _busy,
                            onConnect: () => _connect(account.platform),
                            onOpen: () => _openDetail(_connectorFor(account)),
                          ),
                        const SizedBox(height: 16),
                      ],
                      if (_query.isEmpty && _category == 'all') ...[
                        _SectionLabel('Recommended'),
                        const SizedBox(height: 8),
                        for (final item in _visible.take(6))
                          _ConnectorRow(
                            item: item,
                            connected: _connected(item),
                            busy: _busy,
                            onConnect: () => _connect(item.slug),
                            onOpen: () => _openDetail(item),
                          ),
                        const SizedBox(height: 16),
                      ],
                      for (final cat in _categoryGroups(_visible, _query, _category)) ...[
                        _SectionLabel(cat.$1),
                        const SizedBox(height: 8),
                        for (final item in cat.$2)
                          _ConnectorRow(
                            item: item,
                            connected: _connected(item),
                            busy: _busy,
                            onConnect: () => _connect(item.slug),
                            onOpen: () => _openDetail(item),
                          ),
                        const SizedBox(height: 16),
                      ],
                      const SizedBox(height: 8),
                      _MachineSection(
                        catalog: _catalog,
                        busy: _busy,
                        onYouKey: _setYouKey,
                        onClearYou: () async {
                          setState(() => _busy = true);
                          try {
                            final catalog = await _api.deleteConnection('you');
                            if (!mounted) return;
                            setState(() {
                              _catalog = catalog;
                              _busy = false;
                            });
                          } on Exception catch (e) {
                            if (!mounted) return;
                            setState(() => _busy = false);
                            ShadToaster.of(context).show(
                              ShadToast.destructive(
                                title: const Text('You.com'),
                                description: Text('$e'),
                              ),
                            );
                          }
                        },
                        onStartVoice: () =>
                            context.read<VoiceCubit>().startSidecar(),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

const _categories = <(String, String)>[
  ('all', 'All'),
  ('communication', 'Communication'),
  ('productivity', 'Productivity'),
  ('code', 'Code'),
  ('files', 'Files'),
];

const _connectors = <_Connector>[
  _Connector(
    'gmail',
    'Gmail',
    'communication',
    'Pull mail into memory.',
    LucideIcons.mail,
    Color(0xFFEA4335),
  ),
  _Connector(
    'google-calendar',
    'Google Calendar',
    'communication',
    'Upcoming events as memories.',
    LucideIcons.calendar,
    Color(0xFF4285F4),
  ),
  _Connector(
    'google-docs',
    'Google Docs',
    'productivity',
    'Documents you grant.',
    LucideIcons.fileText,
    Color(0xFF4285F4),
  ),
  _Connector(
    'github',
    'GitHub',
    'code',
    'Activity into the life graph.',
    LucideIcons.gitBranch,
    Color(0xFF24292F),
  ),
  _Connector(
    'slack',
    'Slack',
    'communication',
    'Channels and DMs you grant.',
    LucideIcons.hash,
    Color(0xFF4A154B),
  ),
  _Connector(
    'notion',
    'Notion',
    'productivity',
    'Pages you choose to share.',
    LucideIcons.bookOpen,
    Color(0xFF111111),
  ),
  _Connector(
    'linear',
    'Linear',
    'productivity',
    'Issues and projects.',
    LucideIcons.circleDashed,
    Color(0xFF5E6AD2),
  ),
  _Connector(
    'canva',
    'Canva',
    'productivity',
    'Designs you grant.',
    LucideIcons.palette,
    Color(0xFF00C4CC),
  ),
  _Connector(
    'one-drive',
    'OneDrive',
    'files',
    'Files from Microsoft.',
    LucideIcons.cloud,
    Color(0xFF0078D4),
  ),
  _Connector(
    'discord',
    'Discord',
    'communication',
    'Servers you grant.',
    LucideIcons.messageCircle,
    Color(0xFF5865F2),
  ),
  _Connector(
    'stripe',
    'Stripe',
    'productivity',
    'Payments you grant.',
    LucideIcons.creditCard,
    Color(0xFF635BFF),
  ),
];

List<(String, List<_Connector>)> _categoryGroups(
  List<_Connector> items,
  String query,
  String category,
) {
  if (query.isNotEmpty) {
    return items.isEmpty ? const [] : [('Results', items)];
  }
  if (category != 'all') {
    return items.isEmpty ? const [] : [(_titleFor(category), items)];
  }
  final skip = items.take(6).map((e) => e.slug).toSet();
  final rest = [for (final item in items) if (!skip.contains(item.slug)) item];
  final by = <String, List<_Connector>>{};
  for (final item in rest) {
    (by[item.category] ??= []).add(item);
  }
  return [
    for (final cat in _categories)
      if (cat.$1 != 'all' && (by[cat.$1]?.isNotEmpty ?? false))
        (cat.$2, by[cat.$1]!),
  ];
}

String _titleFor(String id) {
  for (final cat in _categories) {
    if (cat.$1 == id) return cat.$2;
  }
  return id;
}

class _Connector {
  const _Connector(
    this.slug,
    this.title,
    this.category,
    this.description,
    this.icon,
    this.color,
  );

  final String slug;
  final String title;
  final String category;
  final String description;
  final IconData icon;
  final Color color;
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: ShadTheme.of(context).textTheme.muted);
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return ShadButton(size: ShadButtonSize.sm, onPressed: onPressed, child: Text(label));
    }
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

class _ConnectorRow extends StatelessWidget {
  const _ConnectorRow({
    required this.item,
    required this.connected,
    required this.busy,
    required this.onConnect,
    required this.onOpen,
  });

  final _Connector item;
  final bool connected;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              _AppGlyph(item: item),
              const SizedBox(width: 12),
              Expanded(
                child: Text(item.title, style: theme.textTheme.small),
              ),
              if (connected)
                Row(
                  children: [
                    Icon(
                      LucideIcons.check,
                      size: 16,
                      color: theme.colorScheme.foreground,
                    ),
                    const SizedBox(width: 6),
                    Text('Connected', style: theme.textTheme.muted),
                  ],
                )
              else
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  onPressed: busy ? null : onConnect,
                  child: const Text('Connect'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppGlyph extends StatelessWidget {
  const _AppGlyph({required this.item, this.size = 36});

  final _Connector item;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: item.color,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(item.icon, size: size * 0.5, color: Colors.white),
    );
  }
}

class _ConnectorDetail extends StatelessWidget {
  const _ConnectorDetail({
    required this.item,
    required this.account,
    required this.connected,
    required this.busy,
    required this.onConnect,
    required this.onDisconnect,
    required this.onSync,
  });

  final _Connector item;
  final OneAccount? account;
  final bool connected;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Scaffold(
      body: Column(
        children: [
          MaiaHeader(
            title: item.title,
            leading: ShadIconButton.ghost(
              icon: const Icon(LucideIcons.arrowLeft, size: 16),
              onPressed: () => Navigator.of(context).pop(),
            ),
            actions: [
              ShadIconButton.ghost(
                icon: const Icon(LucideIcons.x, size: 16),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  children: [
                    _AppGlyph(item: item, size: 48),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(item.title, style: theme.textTheme.h4),
                    ),
                    if (connected)
                      ShadButton.outline(
                        onPressed: busy ? null : onDisconnect,
                        child: const Text('Disconnect'),
                      )
                    else
                      ShadButton(
                        onPressed: busy ? null : onConnect,
                        child: const Text('Connect'),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(item.description, style: theme.textTheme.muted),
                const SizedBox(height: 24),
                Text('Accounts', style: theme.textTheme.muted),
                const SizedBox(height: 8),
                ShadCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          account?.label ?? 'default',
                          style: theme.textTheme.small,
                        ),
                      ),
                      Text(
                        connected ? 'Connected' : 'Off',
                        style: theme.textTheme.muted.copyWith(
                          color: connected
                              ? const Color(0xFF34C759)
                              : theme.colorScheme.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
                if (connected) ...[
                  const SizedBox(height: 16),
                  ShadButton.outline(
                    onPressed: busy ? null : onSync,
                    child: const Text('Sync now'),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'OAuth stays at One. Maia stores a grant pointer, not the token.',
                  style: theme.textTheme.muted,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MachineSection extends StatelessWidget {
  const _MachineSection({
    required this.catalog,
    required this.busy,
    required this.onYouKey,
    required this.onClearYou,
    required this.onStartVoice,
  });

  final ChatCatalog? catalog;
  final bool busy;
  final VoidCallback onYouKey;
  final VoidCallback onClearYou;
  final VoidCallback onStartVoice;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final you = catalog?.connections.cast<ChatConnection?>().firstWhere(
          (c) => c?.id == 'you',
          orElse: () => null,
        );
    final voice = catalog?.connections.cast<ChatConnection?>().firstWhere(
          (c) => c?.id == 'voice',
          orElse: () => null,
        );
    final provider = context.watch<ChatSettingsCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('This machine', style: theme.textTheme.muted),
        const SizedBox(height: 8),
        ShadCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('You.com', style: theme.textTheme.small),
              const SizedBox(height: 4),
              Text(
                'Web search for the agent.',
                style: theme.textTheme.muted,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ShadButton.outline(
                    size: ShadButtonSize.sm,
                    onPressed: busy ? null : onYouKey,
                    child: Text(you?.connected == true ? 'Replace key' : 'Add key'),
                  ),
                  if (you?.hasSecret == true)
                    ShadButton.ghost(
                      size: ShadButtonSize.sm,
                      onPressed: busy ? null : onClearYou,
                      child: const Text('Use server key'),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Brain', style: theme.textTheme.small),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final id in const ['auto', 'parasail', 'ollama'])
                    _ProviderChip(
                      id: id,
                      selected: provider == id,
                      info: catalog?.providers[id],
                      onPressed: () =>
                          context.read<ChatSettingsCubit>().setProvider(id),
                    ),
                ],
              ),
              if (voice != null) ...[
                const SizedBox(height: 16),
                ShadButton(
                  size: ShadButtonSize.sm,
                  onPressed: busy ? null : onStartVoice,
                  child: Text(
                    voice.connected
                        ? (voice.ready ? 'Keep voice warm' : 'Load voice')
                        : 'Start voice',
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _YouKeyDialog extends StatefulWidget {
  const _YouKeyDialog();

  @override
  State<_YouKeyDialog> createState() => _YouKeyDialogState();
}

class _YouKeyDialogState extends State<_YouKeyDialog> {
  final _key = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('You.com key'),
      description: const Text(
        'From you.com or key.txt. Stored for this person on the server. '
        'Never shown again.',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(context).pop(_key.text.trim()),
          child: const Text('Save'),
        ),
      ],
      child: ShadInput(
        controller: _key,
        obscureText: true,
        placeholder: const Text('YDC_API_KEY'),
      ),
    );
  }
}

class _ProviderChip extends StatelessWidget {
  const _ProviderChip({
    required this.id,
    required this.selected,
    required this.onPressed,
    this.info,
  });

  final String id;
  final bool selected;
  final ChatProviderInfo? info;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = switch (id) {
      'parasail' => 'Parasail',
      'ollama' => 'Local',
      _ => 'Auto',
    };
    final missing = id != 'auto' && info != null && !info!.available;
    final child = Text(missing ? '$label (off)' : label);
    if (selected) {
      return ShadButton(
        size: ShadButtonSize.sm,
        onPressed: missing ? null : onPressed,
        child: child,
      );
    }
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      onPressed: missing ? null : onPressed,
      child: child,
    );
  }
}
