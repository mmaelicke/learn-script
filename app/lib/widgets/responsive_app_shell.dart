import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../shell/app_shell_breakpoint.dart';
import '../shell/primary_add_handler.dart';
import '../ui/de_strings.dart';

final RouteObserver<PageRoute<dynamic>> appShellRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

class InstantShellRoute<T> extends PageRouteBuilder<T> {
  InstantShellRoute({required WidgetBuilder builder, super.settings})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      );
}

class ShellChromeEntry {
  const ShellChromeEntry({
    required this.id,
    this.title,
    this.leading,
    this.actions = const [],
  });

  final int id;
  final String? title;
  final Widget? leading;
  final List<Widget> actions;

  ShellChromeEntry copyWith({
    String? title,
    Widget? leading,
    bool clearLeading = false,
    List<Widget>? actions,
  }) {
    return ShellChromeEntry(
      id: id,
      title: title ?? this.title,
      leading: clearLeading ? null : leading ?? this.leading,
      actions: actions ?? this.actions,
    );
  }
}

class ShellChromeController extends ChangeNotifier {
  final List<ShellChromeEntry> _stack = [];
  int _nextId = 1;

  ShellChromeEntry? get current => _stack.isEmpty ? null : _stack.last;

  int push({String? title, Widget? leading, List<Widget> actions = const []}) {
    final id = _nextId++;
    _stack.add(
      ShellChromeEntry(
        id: id,
        title: title,
        leading: leading,
        actions: actions,
      ),
    );
    notifyListeners();
    return id;
  }

  void update(
    int id, {
    String? title,
    Widget? leading,
    bool clearLeading = false,
    List<Widget>? actions,
  }) {
    final index = _stack.indexWhere((entry) => entry.id == id);
    if (index < 0) {
      return;
    }
    _stack[index] = _stack[index].copyWith(
      title: title,
      leading: leading,
      clearLeading: clearLeading,
      actions: actions,
    );
    notifyListeners();
  }

  void activate(int id) {
    final index = _stack.indexWhere((entry) => entry.id == id);
    if (index < 0 || index == _stack.length - 1) {
      return;
    }
    final entry = _stack.removeAt(index);
    _stack.add(entry);
    notifyListeners();
  }

  void pop(int id) {
    _stack.removeWhere((entry) => entry.id == id);
    notifyListeners();
  }

  void discard(int id) {
    _stack.removeWhere((entry) => entry.id == id);
  }
}

class ShellChrome extends InheritedNotifier<ShellChromeController> {
  const ShellChrome({
    required ShellChromeController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static ShellChromeController of(BuildContext context) {
    final inherited = context.dependOnInheritedWidgetOfExactType<ShellChrome>();
    assert(inherited != null, 'ShellChrome missing above this context');
    return inherited!.notifier!;
  }

  static ShellChromeController read(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<ShellChrome>();
    final widget = element?.widget;
    assert(widget is ShellChrome, 'ShellChrome missing above this context');
    return (widget as ShellChrome).notifier!;
  }
}

/// Responsive chrome: header (title, burger, logout), mobile bottom bar + center
/// FAB below [kAppShellBreakpointWidth], desktop [NavigationRail] + burger toggles
/// extended vs icon-only at or above the breakpoint.
class ResponsiveAppShell extends StatefulWidget {
  const ResponsiveAppShell({
    required this.body,
    this.chromeController,
    this.innerNavigatorKey,
    super.key,
  });

  final Widget body;
  final ShellChromeController? chromeController;

  /// When set, the green FAB opens flows on this [Navigator] (shell body stack).
  final GlobalKey<NavigatorState>? innerNavigatorKey;

  @override
  State<ResponsiveAppShell> createState() => _ResponsiveAppShellState();
}

class _ResponsiveAppShellState extends State<ResponsiveAppShell> {
  final GlobalKey<ScaffoldState> _mobileScaffoldKey =
      GlobalKey<ScaffoldState>();
  final ShellChromeController _fallbackChromeController =
      ShellChromeController();
  bool _railExtended = true;

  static const Color _fabGreen = Color(0xFF2E7D32);

  ShellChromeController get _chromeController =>
      widget.chromeController ?? _fallbackChromeController;

  @override
  void dispose() {
    _fallbackChromeController.dispose();
    super.dispose();
  }

  bool _desktopWidth(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= kAppShellBreakpointWidth;

  void _onBurgerPressed(BuildContext context) {
    if (_desktopWidth(context)) {
      setState(() => _railExtended = !_railExtended);
    } else {
      _mobileScaffoldKey.currentState?.openDrawer();
    }
  }

  void _goHome() {
    final navigator = widget.innerNavigatorKey?.currentState;
    if (navigator != null) {
      navigator.popUntil((route) => route.isFirst);
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Widget _greenAddFab({String tooltip = DeStrings.fabAddNote}) {
    return FloatingActionButton(
      onPressed: () => handlePrimaryAdd(
        context,
        innerNavigatorKey: widget.innerNavigatorKey,
      ),
      backgroundColor: _fabGreen,
      foregroundColor: Colors.white,
      tooltip: tooltip,
      child: const Icon(Icons.add),
    );
  }

  PreferredSizeWidget _appBar(
    BuildContext context, {
    required String burgerTooltip,
  }) {
    final auth = AuthInherited.of(context);
    return AppBar(
      title: AnimatedBuilder(
        animation: _chromeController,
        builder: (context, _) {
          final title = _chromeController.current?.title;
          return Text(title ?? '');
        },
      ),
      centerTitle: true,
      leading: AnimatedBuilder(
        animation: _chromeController,
        builder: (context, _) {
          final leading = _chromeController.current?.leading;
          if (leading != null) {
            return leading;
          }
          return IconButton(
            icon: const Icon(Icons.menu),
            tooltip: burgerTooltip,
            onPressed: () => _onBurgerPressed(context),
          );
        },
      ),
      actions: [
        AnimatedBuilder(
          animation: _chromeController,
          builder: (context, _) {
            final actions = _chromeController.current?.actions ?? const [];
            return Row(mainAxisSize: MainAxisSize.min, children: actions);
          },
        ),
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Sign out',
          onPressed: () => auth.signOut(),
        ),
      ],
    );
  }

  PreferredSizeWidget _desktopContentBar(BuildContext context) {
    final auth = AuthInherited.of(context);
    return AppBar(
      automaticallyImplyLeading: false,
      primary: false,
      title: AnimatedBuilder(
        animation: _chromeController,
        builder: (context, _) {
          final title = _chromeController.current?.title;
          return Text(title ?? '');
        },
      ),
      centerTitle: true,
      leading: AnimatedBuilder(
        animation: _chromeController,
        builder: (context, _) {
          return _chromeController.current?.leading ?? const SizedBox.shrink();
        },
      ),
      actions: [
        AnimatedBuilder(
          animation: _chromeController,
          builder: (context, _) {
            final actions = _chromeController.current?.actions ?? const [];
            return Row(mainAxisSize: MainAxisSize.min, children: actions);
          },
        ),
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Sign out',
          onPressed: () => auth.signOut(),
        ),
      ],
    );
  }

  Widget _mobileDrawer(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                'More',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              subtitle: const Text('Coming soon'),
              onTap: () {
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Help'),
              subtitle: const Text('Coming soon'),
              onTap: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _disabledBottomSlot({
    required IconData icon,
    required String semanticLabel,
    required String tooltip,
  }) {
    final theme = Theme.of(context);
    final color = theme.disabledColor;
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: false,
        label: semanticLabel,
        hint: 'Not available yet',
        child: Tooltip(
          message: tooltip,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: null,
              canRequestFocus: true,
              child: Center(
                child: IconTheme.merge(
                  data: IconThemeData(color: color, size: 26),
                  child: Icon(icon),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _homeBottomSlot() {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: true,
        label: 'Home',
        child: Tooltip(
          message: 'Fächer',
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: _goHome,
              canRequestFocus: true,
              child: Center(
                child: IconTheme.merge(
                  data: IconThemeData(
                    color: theme.colorScheme.primary,
                    size: 26,
                  ),
                  child: const Icon(Icons.folder_outlined),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobile(BuildContext context) {
    return Scaffold(
      key: _mobileScaffoldKey,
      appBar: _appBar(context, burgerTooltip: 'Open menu'),
      drawer: _mobileDrawer(context),
      body: widget.body,
      floatingActionButton: _greenAddFab(tooltip: DeStrings.fabAddNote),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        padding: EdgeInsets.zero,
        height: 56,
        shape: const CircularNotchedRectangle(),
        notchMargin: 6,
        child: Row(
          children: [
            Expanded(child: _homeBottomSlot()),
            const SizedBox(width: 72),
            Expanded(
              child: _disabledBottomSlot(
                icon: Icons.star_border,
                semanticLabel: 'Primary tab, coming soon',
                tooltip: 'Coming soon',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktop(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.38);
    final railTheme = NavigationRailThemeData(
      selectedIconTheme: IconThemeData(color: theme.colorScheme.primary),
      unselectedIconTheme: IconThemeData(color: muted),
      selectedLabelTextStyle: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.primary,
      ),
      unselectedLabelTextStyle: theme.textTheme.bodySmall?.copyWith(
        color: muted,
      ),
      useIndicator: false,
    );

    final burgerTooltip = _railExtended
        ? 'Use compact navigation'
        : 'Show navigation labels';

    return Scaffold(
      floatingActionButton: _greenAddFab(tooltip: DeStrings.fabAddNote),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _railExtended ? 256 : 72,
            child: Column(
              children: [
                SizedBox(
                  height: kToolbarHeight,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: IconButton(
                        icon: const Icon(Icons.menu),
                        tooltip: burgerTooltip,
                        onPressed: () => _onBurgerPressed(context),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: NavigationRailTheme(
                    data: railTheme,
                    child: NavigationRail(
                      extended: _railExtended,
                      selectedIndex: 0,
                      groupAlignment: -1,
                      onDestinationSelected: (index) {
                        if (index == 0) {
                          _goHome();
                        }
                      },
                      labelType: NavigationRailLabelType.none,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.folder_outlined),
                          selectedIcon: Icon(Icons.folder_outlined),
                          label: Text('Fächer'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.star_border),
                          selectedIcon: Icon(Icons.star_border),
                          label: Text('Coming soon'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Column(
              children: [
                _desktopContentBar(context),
                Expanded(child: widget.body),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop =
        MediaQuery.sizeOf(context).width >= kAppShellBreakpointWidth;
    return desktop ? _buildDesktop(context) : _buildMobile(context);
  }
}
