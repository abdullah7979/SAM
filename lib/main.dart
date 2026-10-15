import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  runApp(const MasroofApp());
}

const _navy = Color(0xFF101A2D);
const _ink = Color(0xFF172338);
const _muted = Color(0xFF8390A3);
const _paper = Color(0xFFF5F7FB);
const _violet = Color(0xFF7357F6);
const _mint = Color(0xFF34C9A2);
const _pink = Color(0xFFEF5DA8);
const _orange = Color(0xFFFFB84D);

class MasroofApp extends StatefulWidget {
  const MasroofApp({super.key});
  @override
  State<MasroofApp> createState() => _MasroofAppState();
}

class _MasroofAppState extends State<MasroofApp> {
  bool english = false;
  void setLanguage(bool value) => setState(() => english = value);
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'المصروف الذكي',
    locale: Locale(english ? 'en' : 'ar'),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: _paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _violet,
        brightness: Brightness.light,
      ),
      fontFamily: 'Roboto',
      appBarTheme: const AppBarTheme(
        backgroundColor: _paper,
        foregroundColor: _ink,
        elevation: 0,
      ),
    ),
    home: FinanceHome(english: english, onLanguageChanged: setLanguage),
  );
}

String t(bool en, String ar, String eng) => en ? eng : ar;
String money(double amount) =>
    '${NumberFormat('#,##0.00', 'en').format(amount)} ر.س';

class FinanceTransaction {
  FinanceTransaction({
    required this.title,
    required this.category,
    required this.amount,
    required this.date,
    required this.kind,
    this.bank = '',
    this.card = '',
    this.note = '',
  });
  final String title, category, kind, bank, card, note;
  final double amount;
  final DateTime date;
  Map<String, dynamic> toJson() => {
    'title': title,
    'category': category,
    'amount': amount,
    'date': date.toIso8601String(),
    'kind': kind,
    'bank': bank,
    'card': card,
    'note': note,
  };
  factory FinanceTransaction.fromJson(Map<String, dynamic> j) =>
      FinanceTransaction(
        title: j['title'] ?? '',
        category: j['category'] ?? 'أخرى',
        amount: (j['amount'] as num).toDouble(),
        date: DateTime.tryParse(j['date'] ?? '') ?? DateTime.now(),
        kind: j['kind'] ?? 'expense',
        bank: j['bank'] ?? '',
        card: j['card'] ?? '',
        note: j['note'] ?? '',
      );
}

class FinanceHome extends StatefulWidget {
  const FinanceHome({
    super.key,
    required this.english,
    required this.onLanguageChanged,
  });
  final bool english;
  final ValueChanged<bool> onLanguageChanged;
  @override
  State<FinanceHome> createState() => _FinanceHomeState();
}

class _FinanceHomeState extends State<FinanceHome> with WidgetsBindingObserver {
  static const _channel = MethodChannel('sa.masroof.smart/sms');
  int _tab = 0;
  String _transactionFilter = 'all';
  bool _loaded = false;
  bool _importingSms = false;
  DateTime? _lastAutomaticSmsSync;
  DateTime _budgetStart = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    1,
  );
  DateTime? _budgetEnd;
  DateTime _reportStart = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    1,
  );
  DateTime _reportEnd = DateTime.now();
  double _monthlyBudget = 5000;
  String _period = 'month';
  List<FinanceTransaction> _transactions = [];
  final Map<String, bool> _banks = {
    'مصرف الراجحي': true,
    'الأهلي السعودي': false,
    'بنك الرياض': false,
    'مصرف الإنماء': false,
    'بنك البلاد': false,
    'البنك السعودي الأول': false,
    'البنك العربي الوطني': false,
    'بنك الجزيرة': false,
    'بنك الخليج الدولي': false,
    'البنك السعودي للاستثمار': false,
    'بنك الإمارات دبي الوطني': false,
    'بنك D360': false,
    'بنك إس تي سي': false,
  };
  final Map<String, double> _categoryBudgets = {
    'طعام ومقاهي': 900,
    'بنزين ومواصلات': 500,
    'التسوق': 700,
    'فواتير': 650,
    'ترفيه': 350,
    'أخرى': 400,
  };
  bool get en => widget.english;

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
    if (state == AppLifecycleState.resumed && _loaded) {
      final now = DateTime.now();
      if (_lastAutomaticSmsSync == null ||
          now.difference(_lastAutomaticSmsSync!) >
              const Duration(seconds: 30)) {
        _lastAutomaticSmsSync = now;
        _importSms(silent: true);
      }
    }
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('transactions');
    if (saved != null) {
      _transactions = (jsonDecode(saved) as List)
          .map((e) => FinanceTransaction.fromJson(e))
          .toList();
    } else {
      _transactions = [
        FinanceTransaction(
          title: 'تموينات الحي',
          category: 'طعام ومقاهي',
          amount: 86.50,
          date: DateTime.now().subtract(const Duration(hours: 2)),
          kind: 'expense',
          bank: 'مصرف الراجحي',
          card: '4821',
        ),
        FinanceTransaction(
          title: 'راتب شهري',
          category: 'دخل',
          amount: 8200,
          date: DateTime.now().subtract(const Duration(days: 1)),
          kind: 'income',
          bank: 'مصرف الراجحي',
        ),
        FinanceTransaction(
          title: 'محطة وقود',
          category: 'بنزين ومواصلات',
          amount: 145,
          date: DateTime.now().subtract(const Duration(days: 2)),
          kind: 'expense',
          bank: 'مصرف الراجحي',
          card: '4821',
        ),
        FinanceTransaction(
          title: 'تحويل إلى سارة',
          category: 'تحويل',
          amount: 300,
          date: DateTime.now().subtract(const Duration(days: 3)),
          kind: 'transfer',
        ),
      ];
    }
    final bankJson = p.getString('banks');
    if (bankJson != null)
      (jsonDecode(bankJson) as Map<String, dynamic>).forEach((k, v) {
        if (_banks.containsKey(k)) _banks[k] = v == true;
      });
    _monthlyBudget = p.getDouble('budget') ?? 5000;
    _budgetStart =
        DateTime.tryParse(p.getString('budgetStart') ?? '') ?? _budgetStart;
    _budgetEnd = DateTime.tryParse(p.getString('budgetEnd') ?? '');
    final categoryJson = p.getString('categoryBudgets');
    if (categoryJson != null)
      (jsonDecode(categoryJson) as Map<String, dynamic>).forEach((k, v) {
        if (_categoryBudgets.containsKey(k))
          _categoryBudgets[k] = (v as num).toDouble();
      });
    if (mounted) {
      setState(() {
        _loaded = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _lastAutomaticSmsSync = DateTime.now();
          _importSms(silent: true);
        }
      });
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      'transactions',
      jsonEncode(_transactions.map((e) => e.toJson()).toList()),
    );
    await p.setString('banks', jsonEncode(_banks));
    await p.setDouble('budget', _monthlyBudget);
    await p.setString('budgetStart', _budgetStart.toIso8601String());
    if (_budgetEnd != null) {
      await p.setString('budgetEnd', _budgetEnd!.toIso8601String());
    } else {
      await p.remove('budgetEnd');
    }
    await p.setString('categoryBudgets', jsonEncode(_categoryBudgets));
  }

  double get _expenses => _transactions
      .where((x) => x.kind == 'expense')
      .fold<double>(0, (s, x) => s + x.amount);
  double get _income => _transactions
      .where((x) => x.kind == 'income')
      .fold<double>(0, (s, x) => s + x.amount);
  double get _spentInPeriod => _transactions
      .where(
        (x) =>
            x.kind == 'expense' &&
            !x.date.isBefore(_budgetStart) &&
            (_budgetEnd == null ||
                !x.date.isAfter(
                  DateTime(
                    _budgetEnd!.year,
                    _budgetEnd!.month,
                    _budgetEnd!.day,
                    23,
                    59,
                    59,
                  ),
                )),
      )
      .fold<double>(0, (s, x) => s + x.amount);
  List<FinanceTransaction> get _reportTransactions =>
      _transactions
          .where(
            (x) =>
                !x.date.isBefore(_reportStart) &&
                !x.date.isAfter(
                  DateTime(
                    _reportEnd.year,
                    _reportEnd.month,
                    _reportEnd.day,
                    23,
                    59,
                    59,
                  ),
                ),
          )
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
  double get _reportExpenses => _reportTransactions
      .where((x) => x.kind == 'expense')
      .fold<double>(0, (s, x) => s + x.amount);
  int get _daysLeft => math
      .max(
        0,
        ((_budgetEnd ??
                DateTime(
                  _budgetStart.year,
                  _budgetStart.month + 1,
                  _budgetStart.day,
                ))
            .difference(DateTime.now())
            .inDays),
      )
      .toInt();

  @override
  Widget build(BuildContext context) {
    final pages = [
      _dashboard(),
      _transactionsPage(),
      _budgetsPage(),
      _banksPage(),
      _reportsPage(),
      _settingsPage(),
    ];
    return Directionality(
      textDirection: en ? ui.TextDirection.ltr : ui.TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : IndexedStack(index: _tab, children: pages),
        ),
        floatingActionButton: FloatingActionButton.large(
          onPressed: _addTransaction,
          backgroundColor: _violet,
          foregroundColor: Colors.white,
          elevation: 8,
          child: const Icon(Icons.add_rounded, size: 32),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        bottomNavigationBar: _bottomBar(),
      ),
    );
  }

  Widget _bottomBar() => BottomAppBar(
    height: 72,
    color: Colors.white,
    surfaceTintColor: Colors.white,
    elevation: 12,
    shape: const CircularNotchedRectangle(),
    notchMargin: 8,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: List.generate(5, (i) {
        final icons = [
          Icons.home_rounded,
          Icons.receipt_long_rounded,
          Icons.donut_large_rounded,
          Icons.insights_rounded,
          Icons.tune_rounded,
        ];
        final labels = en
            ? ['Home', 'Activity', 'Budgets', 'Reports', 'Settings']
            : ['الرئيسية', 'العمليات', 'الميزانيات', 'التقارير', 'الإعدادات'];
        if (i == 2) return const SizedBox(width: 56);
        final ix = i > 2 ? i + 1 : i;
        return InkWell(
          onTap: () => setState(() => _tab = ix),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icons[i], color: _tab == ix ? _violet : _muted, size: 22),
                Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 10,
                    color: _tab == ix ? _violet : _muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    ),
  );

  Widget _header(String title, {String? subtitle, Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    subtitle,
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        trailing ?? const SizedBox(),
      ],
    ),
  );
  Widget _scroll(List<Widget> children) =>
      ListView(padding: const EdgeInsets.only(bottom: 100), children: children);
  Widget _dashboard() => _scroll([
    _header(
      t(en, 'مساء الخير 👋', 'Good evening 👋'),
      subtitle: t(en, 'هذه لمحتك المالية اليوم', 'Your money at a glance'),
      trailing: _circleButton(
        Icons.notifications_none_rounded,
        () => setState(() => _tab = 4),
      ),
    ),
    _balanceCard(),
    _quickStats(),
    _sectionTitle(
      t(en, 'ميزانية الشهر', 'Monthly budget'),
      t(en, 'عرض الكل', 'See all'),
      () => setState(() => _tab = 2),
    ),
    _budgetSummary(),
    _sectionTitle(
      t(en, 'مصروفاتك حسب الفئة', 'Spending by category'),
      t(en, 'التقارير', 'Reports'),
      () => setState(() => _tab = 4),
    ),
    _categoryChart(),
    _sectionTitle(
      t(en, 'آخر العمليات', 'Recent activity'),
      t(en, 'عرض الكل', 'See all'),
      () => setState(() => _tab = 1),
    ),
    ..._transactions.take(4).map(_transactionTile),
    const SizedBox(height: 20),
  ]);

  Widget _balanceCard() {
    final remain = (_monthlyBudget - _spentInPeriod)
        .clamp(0, double.infinity)
        .toDouble();
    final ratio = _monthlyBudget <= 0
        ? 0.0
        : (_spentInPeriod / _monthlyBudget).clamp(0.0, 1.0).toDouble();
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 4, 18, 14),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF111C32), Color(0xFF242F51), Color(0xFF473E8A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: _violet.withOpacity(.2),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t(en, 'إجمالي المصروفات', 'Total spending'),
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
              const Icon(Icons.more_horiz, color: Colors.white70),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            money(_spentInPeriod),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -.5,
            ),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(_mint),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '${(ratio * 100).round()}% ${t(en, 'من الميزانية', 'of budget')}',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const Spacer(),
              Text(
                '${t(en, 'المتبقي', 'Remaining')} ${money(remain)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              const Icon(Icons.calendar_month_rounded, color: _mint, size: 16),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${t(en, 'من', 'From')} ${DateFormat('d MMM', en ? 'en' : 'ar').format(_budgetStart)}  •  ${t(en, 'باقي', '')} $_daysLeft ${t(en, 'يوم', 'days left')}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
              TextButton(
                onPressed: _editBudget,
                child: Text(
                  t(en, 'تعديل', 'Edit'),
                  style: const TextStyle(color: _mint),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quickStats() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18),
    child: Row(
      children: [
        _statCard(
          t(en, 'الدخل', 'Income'),
          money(_income),
          Icons.south_west_rounded,
          _mint,
        ),
        const SizedBox(width: 10),
        _statCard(
          t(en, 'المدخرات', 'Savings'),
          money((_income - _expenses).clamp(0, double.infinity).toDouble()),
          Icons.savings_outlined,
          _violet,
        ),
      ],
    ),
  );
  Widget _statCard(String label, String value, IconData icon, Color color) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 29,
                    height: 29,
                    decoration: BoxDecoration(
                      color: color.withOpacity(.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: color, size: 17),
                  ),
                  const Spacer(),
                  Icon(Icons.arrow_outward_rounded, color: color, size: 15),
                ],
              ),
              const SizedBox(height: 12),
              Text(label, style: const TextStyle(fontSize: 11, color: _muted)),
              const SizedBox(height: 3),
              FittedBox(
                alignment: AlignmentDirectional.centerStart,
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _ink,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  Widget _sectionTitle(String title, String action, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
            ),
            TextButton(
              onPressed: onTap,
              child: Text(
                action,
                style: const TextStyle(
                  color: _violet,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      );
  Widget _budgetSummary() => Container(
    margin: const EdgeInsets.symmetric(horizontal: 18),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
    ),
    child: Column(
      children: _categoryBudgets.entries.take(3).map((e) {
        final used = _spentForCategory(e.key);
        final p = e.value <= 0
            ? 0.0
            : (used / e.value).clamp(0.0, 1.0).toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _catColor(e.key).withOpacity(.13),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(_catIcon(e.key), color: _catColor(e.key), size: 18),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            en ? _translateCategory(e.key) : e.key,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _ink,
                            ),
                          ),
                        ),
                        Text(
                          '${money(used)} / ${money(e.value)}',
                          style: const TextStyle(fontSize: 10, color: _muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: LinearProgressIndicator(
                        value: p,
                        minHeight: 5,
                        backgroundColor: _paper,
                        valueColor: AlwaysStoppedAnimation(
                          p >= 1 ? _pink : _catColor(e.key),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    ),
  );
  double _spentForCategory(String cat) => _transactions
      .where(
        (x) =>
            x.kind == 'expense' &&
            x.category == cat &&
            !x.date.isBefore(_budgetStart) &&
            (_budgetEnd == null ||
                !x.date.isAfter(
                  DateTime(
                    _budgetEnd!.year,
                    _budgetEnd!.month,
                    _budgetEnd!.day,
                    23,
                    59,
                    59,
                  ),
                )),
      )
      .fold<double>(0, (s, x) => s + x.amount);
  Color _catColor(String c) => c.contains('طعام')
      ? _pink
      : c.contains('بنزين')
      ? _orange
      : c.contains('فواتير')
      ? _violet
      : _mint;
  IconData _catIcon(String c) => c.contains('طعام')
      ? Icons.restaurant_rounded
      : c.contains('بنزين')
      ? Icons.local_gas_station_rounded
      : c.contains('تسوق')
      ? Icons.shopping_bag_rounded
      : Icons.receipt_long_rounded;
  Widget _categoryChart() {
    final entries = _categoryBudgets.keys
        .map((key) => MapEntry(key, _spentForCategory(key)))
        .where((entry) => entry.value > 0)
        .toList();
    final total = entries.fold<double>(0, (sum, entry) => sum + entry.value);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 18),
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            height: 110,
            child: CustomPaint(
              painter: DonutPainter(
                values: entries.map((entry) => entry.value).toList(),
                colors: entries.map((entry) => _catColor(entry.key)).toList(),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      t(en, 'الإجمالي', 'Total'),
                      style: const TextStyle(color: _muted, fontSize: 10),
                    ),
                    Text(
                      NumberFormat.compact().format(total),
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              children: entries.isEmpty
                  ? [
                      Text(
                        t(
                          en,
                          'أضف عمليات لتظهر تحليلاتك هنا',
                          'Add transactions to see insights',
                        ),
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                    ]
                  : entries
                        .take(4)
                        .map(
                          (entry) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: _catColor(entry.key),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    en
                                        ? _translateCategory(entry.key)
                                        : entry.key,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: _ink,
                                    ),
                                  ),
                                ),
                                Text(
                                  money(entry.value),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: _muted,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
            ),
          ),
        ],
      ),
    );
  }

  String _translateCategory(String c) =>
      {
        'طعام ومقاهي': 'Food & coffee',
        'بنزين ومواصلات': 'Transport',
        'التسوق': 'Shopping',
        'فواتير': 'Bills',
        'ترفيه': 'Leisure',
        'أخرى': 'Other',
        'دخل': 'Income',
        'تحويل': 'Transfer',
        'قرض': 'Loan',
      }[c] ??
      c;

  Widget _transactionsPage() => _scroll([
    _header(
      t(en, 'العمليات', 'Activity'),
      subtitle: t(
        en,
        'كل حركاتك المالية في مكان واحد',
        'All your money movements in one place',
      ),
      trailing: _circleButton(Icons.filter_list_rounded, _choosePeriod),
    ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          _filterChip(
            t(en, 'الكل', 'All'),
            _transactionFilter == 'all',
            () => setState(() => _transactionFilter = 'all'),
          ),
          const SizedBox(width: 8),
          _filterChip(
            t(en, 'مصروفات', 'Expenses'),
            _transactionFilter == 'expense',
            () => setState(() => _transactionFilter = 'expense'),
          ),
          const SizedBox(width: 8),
          _filterChip(
            t(en, 'دخل', 'Income'),
            _transactionFilter == 'income',
            () => setState(() => _transactionFilter = 'income'),
          ),
        ],
      ),
    ),
    const SizedBox(height: 10),
    ..._transactions
        .where(
          (x) => _transactionFilter == 'all' || x.kind == _transactionFilter,
        )
        .map(_transactionTile),
  ]);
  Widget _filterChip(String label, bool selected, VoidCallback tap) =>
      ActionChip(
        onPressed: tap,
        label: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: selected ? Colors.white : _muted,
          ),
        ),
        backgroundColor: selected ? _violet : Colors.white,
        side: BorderSide.none,
      );
  Widget _transactionTile(FinanceTransaction x) {
    final income = x.kind == 'income';
    final icon = x.kind == 'transfer'
        ? Icons.swap_horiz_rounded
        : income
        ? Icons.south_west_rounded
        : _catIcon(x.category);
    final color = x.kind == 'transfer'
        ? _violet
        : income
        ? _mint
        : _catColor(x.category);
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 5, 18, 5),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 43,
            height: 43,
            decoration: BoxDecoration(
              color: color.withOpacity(.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  x.title,
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${en ? _translateCategory(x.category) : x.category}  •  ${DateFormat('d MMM, HH:mm', en ? 'en' : 'ar').format(x.date)}',
                  style: const TextStyle(color: _muted, fontSize: 10),
                ),
                if (x.bank.isNotEmpty)
                  Text(
                    '${x.bank}${x.card.isNotEmpty ? ' • •••• ${x.card}' : ''}',
                    style: const TextStyle(color: _muted, fontSize: 9),
                  ),
              ],
            ),
          ),
          Text(
            '${income
                ? '+'
                : x.kind == 'transfer'
                ? '↔'
                : '−'} ${money(x.amount)}',
            style: TextStyle(
              color: income ? _mint : _ink,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _budgetsPage() => _scroll([
    _header(
      t(en, 'ميزانياتي', 'My budgets'),
      subtitle: t(
        en,
        'راقب حدودك الشهرية بسهولة',
        'Keep your spending on track',
      ),
      trailing: _circleButton(Icons.add, _editBudget),
    ),
    Container(
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6650E8), Color(0xFF9868FA)],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t(en, 'الميزانية الكلية', 'Total budget'),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 7),
                Text(
                  money(_monthlyBudget),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '${t(en, 'مصروف', 'Spent')} ${money(_spentInPeriod)}  •  ${t(en, 'متبقي', 'Left')} ${money((_monthlyBudget - _spentInPeriod).clamp(0, double.infinity).toDouble())}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 78,
            height: 78,
            child: CustomPaint(
              painter: DonutPainter(
                values: [
                  _spentInPeriod,
                  (_monthlyBudget - _spentInPeriod)
                      .clamp(0, double.infinity)
                      .toDouble(),
                ],
                colors: [_mint, Colors.white24],
                stroke: 8,
              ),
              child: Center(
                child: Text(
                  '${_monthlyBudget == 0 ? 0 : (_spentInPeriod / _monthlyBudget * 100).round()}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Text(
        t(en, 'ميزانيات الفئات', 'Category budgets'),
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w800,
          color: _ink,
        ),
      ),
    ),
    ..._categoryBudgets.entries.map(_budgetTile),
    const SizedBox(height: 12),
  ]);
  Widget _budgetTile(MapEntry<String, double> e) {
    final used = _spentForCategory(e.key),
        ratio = e.value == 0
            ? 0.0
            : (used / e.value).clamp(0.0, 1.0).toDouble();
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 5, 18, 5),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _catColor(e.key).withOpacity(.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(_catIcon(e.key), color: _catColor(e.key)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      en ? _translateCategory(e.key) : e.key,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${t(en, 'حد الميزانية', 'Limit')} ${money(e.value)}',
                      style: const TextStyle(color: _muted, fontSize: 10),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => _editCategoryBudget(e.key, e.value),
                icon: const Icon(Icons.edit_outlined, color: _muted, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 7,
              backgroundColor: _paper,
              valueColor: AlwaysStoppedAnimation(
                ratio >= 1 ? _pink : _catColor(e.key),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Text(
                '${t(en, 'المصروف', 'Spent')} ${money(used)}',
                style: const TextStyle(color: _muted, fontSize: 10),
              ),
              const Spacer(),
              Text(
                ratio >= 1
                    ? t(en, 'تجاوزت الحد', 'Over budget')
                    : '${money(e.value - used)} ${t(en, 'متبقي', 'left')}',
                style: TextStyle(
                  color: ratio >= 1 ? _pink : _muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _reportsPage() => _scroll([
    _header(
      t(en, 'التقارير', 'Reports'),
      subtitle: t(
        en,
        'صورة أوضح عن عاداتك المالية',
        'A clearer view of your money habits',
      ),
      trailing: _circleButton(Icons.date_range_rounded, _choosePeriod),
    ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          _filterChip(
            t(en, 'أسبوعي', 'Week'),
            _period == 'week',
            () => _setReportPeriod('week'),
          ),
          _filterChip(
            t(en, 'شهري', 'Month'),
            _period == 'month',
            () => _setReportPeriod('month'),
          ),
          _filterChip(
            t(en, 'سنوي', 'Year'),
            _period == 'year',
            () => _setReportPeriod('year'),
          ),
        ],
      ),
    ),
    Container(
      margin: const EdgeInsets.fromLTRB(18, 12, 18, 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t(en, 'إجمالي المصروفات', 'Total expenses'),
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 5),
          Text(
            money(_reportExpenses),
            style: const TextStyle(
              color: _ink,
              fontWeight: FontWeight.w800,
              fontSize: 24,
            ),
          ),
          Text(
            '${DateFormat('d MMM', en ? 'en' : 'ar').format(_reportStart)} – ${DateFormat('d MMM', en ? 'en' : 'ar').format(_reportEnd)}',
            style: const TextStyle(fontSize: 10, color: _muted),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 150,
            child: CustomPaint(
              painter: BarsPainter(values: _weeklyBars()),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exportCsv,
                  icon: const Icon(Icons.table_view_rounded),
                  label: Text(t(en, 'Excel / CSV', 'Excel / CSV')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _exportPdf,
                  icon: const Icon(Icons.picture_as_pdf_rounded),
                  label: Text('PDF'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
    _sectionTitle(t(en, 'حسب الفئة', 'By category'), t(en, '', ''), () => {}),
    ..._categoryBudgets.keys.map(_reportCategoryTile),
    const SizedBox(height: 12),
  ]);
  Widget _reportCategoryTile(String category) {
    final amount = _reportTransactions
        .where((x) => x.kind == 'expense' && x.category == category)
        .fold<double>(0, (s, x) => s + x.amount);
    if (amount == 0) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 4, 18, 4),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(_catIcon(category), color: _catColor(category)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              en ? _translateCategory(category) : category,
              style: const TextStyle(color: _ink, fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            money(amount),
            style: const TextStyle(color: _ink, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  List<double> _weeklyBars() {
    final now = DateTime.now();
    return List.generate(7, (i) {
      final day = DateTime(now.year, now.month, now.day - (6 - i));
      return _transactions
          .where(
            (x) =>
                x.kind == 'expense' &&
                x.date.year == day.year &&
                x.date.month == day.month &&
                x.date.day == day.day,
          )
          .fold<double>(0, (s, x) => s + x.amount);
    });
  }

  Widget _settingsPage() => _scroll([
    _header(
      t(en, 'الإعدادات', 'Settings'),
      subtitle: t(
        en,
        'خصص تجربتك وحافظ على خصوصيتك',
        'Personalize your app and privacy',
      ),
    ),
    Container(
      margin: const EdgeInsets.fromLTRB(18, 5, 18, 10),
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: _navy,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFF333E5E),
            child: Icon(Icons.shield_moon_outlined, color: _mint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t(en, 'خصوصيتك أولاً', 'Privacy first'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  t(
                    en,
                    'بياناتك المالية تبقى على جهازك',
                    'Your financial data stays on your device',
                  ),
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    _settingTile(
      Icons.account_balance_rounded,
      t(en, 'حسابات البنوك', 'Bank accounts'),
      t(en, 'تشغيل وإيقاف كل بنك', 'Enable or pause each bank'),
      () => setState(() => _tab = 3),
    ),
    _settingTile(
      Icons.credit_card_rounded,
      t(en, 'البطاقات', 'Cards'),
      t(
        en,
        'ملخص البطاقات حسب العمليات المستوردة',
        'Card summaries from imported transactions',
      ),
      () => setState(() => _tab = 3),
    ),
    _settingTile(
      Icons.flag_outlined,
      t(en, 'الميزانية والأهداف', 'Budget & goals'),
      t(en, 'حدود الإنفاق وأهداف الادخار', 'Spending limits and savings goals'),
      _editBudget,
    ),
    _settingTile(
      Icons.notifications_active_outlined,
      t(en, 'التنبيهات', 'Notifications'),
      t(en, 'تنبيهات العمليات والميزانيات', 'Transaction and budget alerts'),
      () => _snack(
        t(
          en,
          'إعدادات التنبيه التفصيلية قيد الإضافة',
          'Detailed alert settings are coming',
        ),
      ),
    ),
    Container(
      margin: const EdgeInsets.fromLTRB(18, 5, 18, 5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: [
          const Icon(Icons.language_rounded, color: _violet),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              t(en, 'لغة التطبيق', 'App language'),
              style: const TextStyle(color: _ink, fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            en ? 'English' : 'العربية',
            style: const TextStyle(color: _muted),
          ),
          Switch(
            value: en,
            onChanged: widget.onLanguageChanged,
            activeColor: _violet,
          ),
        ],
      ),
    ),
    _settingTile(
      Icons.sms_outlined,
      t(en, 'استيراد رسائل البنك', 'Import bank messages'),
      t(en, 'قراءة محلية بعد موافقتك', 'Local reading with your permission'),
      _importSms,
    ),
    _settingTile(
      Icons.info_outline,
      t(en, 'حول التطبيق', 'About'),
      t(en, 'المصروف الذكي • إصدار أولي', 'Masroof Smart • Early preview'),
      () => _snack(t(en, 'هذه نسخة أولية للتجربة', 'This is an early preview')),
    ),
    const SizedBox(height: 15),
  ]);
  Widget _settingTile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => Container(
    margin: const EdgeInsets.fromLTRB(18, 5, 18, 5),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(17),
    ),
    child: ListTile(
      onTap: onTap,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: _violet.withOpacity(.1),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Icon(icon, color: _violet, size: 20),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: _ink,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 10, color: _muted),
      ),
      trailing: const Icon(Icons.chevron_right, color: _muted),
    ),
  );
  Widget _circleButton(IconData icon, VoidCallback action) => IconButton(
    onPressed: action,
    style: IconButton.styleFrom(backgroundColor: Colors.white),
    icon: Icon(icon, color: _ink),
  );

  Future<void> _addTransaction() async {
    String kind = 'expense';
    String category = 'طعام ومقاهي';
    final amount = TextEditingController();
    final titleController = TextEditingController();
    final categories = [
      'طعام ومقاهي',
      'بنزين ومواصلات',
      'التسوق',
      'فواتير',
      'ترفيه',
      'أخرى',
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
            decoration: const BoxDecoration(
              color: _paper,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _muted.withOpacity(.3),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  t(en, 'عملية جديدة', 'New transaction'),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final entry in [
                      ('expense', t(en, 'مصروف', 'Expense')),
                      ('income', t(en, 'دخل', 'Income')),
                      ('transfer', t(en, 'تحويل', 'Transfer')),
                      ('loan', t(en, 'قرض', 'Loan')),
                    ])
                      ChoiceChip(
                        label: Text(entry.$2),
                        selected: kind == entry.$1,
                        onSelected: (_) => setModal(() => kind = entry.$1),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    labelText: t(en, 'الوصف', 'Description'),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: t(en, 'المبلغ بالريال', 'Amount in SAR'),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                if (kind == 'expense') ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: category,
                    decoration: InputDecoration(
                      labelText: t(en, 'الفئة', 'Category'),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    items: categories
                        .map(
                          (item) => DropdownMenuItem(
                            value: item,
                            child: Text(en ? _translateCategory(item) : item),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setModal(() => category = value ?? category),
                  ),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _violet,
                      padding: const EdgeInsets.all(15),
                    ),
                    onPressed: () {
                      final value = double.tryParse(
                        amount.text.replaceAll(',', '.'),
                      );
                      if (value == null ||
                          value <= 0 ||
                          titleController.text.trim().isEmpty) {
                        _snack(
                          t(
                            en,
                            'أدخل الوصف والمبلغ بشكل صحيح',
                            'Enter a valid description and amount',
                          ),
                        );
                        return;
                      }
                      setState(
                        () => _transactions.insert(
                          0,
                          FinanceTransaction(
                            title: titleController.text.trim(),
                            category: kind == 'income'
                                ? 'دخل'
                                : kind == 'transfer'
                                ? 'تحويل'
                                : kind == 'loan'
                                ? 'قرض'
                                : category,
                            amount: value,
                            date: DateTime.now(),
                            kind: kind,
                          ),
                        ),
                      );
                      _save();
                      Navigator.pop(ctx);
                    },
                    child: Text(t(en, 'حفظ العملية', 'Save transaction')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editBudget() async {
    final controller = TextEditingController(
      text: _monthlyBudget.toStringAsFixed(0),
    );
    DateTime start = _budgetStart;
    DateTime? end = _budgetEnd;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            22,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 22,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t(en, 'إعداد الميزانية', 'Budget settings'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t(en, 'حد الميزانية (ر.س)', 'Budget limit (SAR)'),
                ),
              ),
              ListTile(
                title: Text(t(en, 'تاريخ البداية', 'Start date')),
                subtitle: Text(
                  DateFormat('d MMM yyyy', en ? 'en' : 'ar').format(start),
                ),
                trailing: const Icon(Icons.calendar_month),
                onTap: () async {
                  final date = await showDatePicker(
                    context: ctx,
                    initialDate: start,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (date != null) setModal(() => start = date);
                },
              ),
              ListTile(
                title: Text(
                  t(en, 'تاريخ النهاية الاختياري', 'Optional end date'),
                ),
                subtitle: Text(
                  end == null
                      ? t(en, 'نهاية الشهر تلقائيًا', 'End of month by default')
                      : DateFormat('d MMM yyyy', en ? 'en' : 'ar').format(end!),
                ),
                trailing: const Icon(Icons.event_available),
                onTap: () async {
                  final date = await showDatePicker(
                    context: ctx,
                    initialDate: end ?? start.add(const Duration(days: 29)),
                    firstDate: start,
                    lastDate: DateTime(2100),
                  );
                  if (date != null) setModal(() => end = date);
                },
              ),
              TextButton(
                onPressed: () => setModal(() => end = null),
                child: Text(t(en, 'استخدام نهاية الشهر', 'Use month end')),
              ),
              FilledButton(
                onPressed: () {
                  final value = double.tryParse(controller.text);
                  if (value != null && value > 0) {
                    setState(() {
                      _monthlyBudget = value;
                      _budgetStart = start;
                      _budgetEnd = end;
                    });
                    _save();
                  }
                  Navigator.pop(ctx);
                },
                child: Text(t(en, 'حفظ', 'Save')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editCategoryBudget(String key, double value) async {
    final controller = TextEditingController(text: value.toStringAsFixed(0));
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(en ? _translateCategory(key) : key),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: t(en, 'حد الميزانية (ر.س)', 'Budget limit (SAR)'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t(en, 'إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              final budget = double.tryParse(controller.text);
              if (budget != null && budget > 0) {
                setState(() => _categoryBudgets[key] = budget);
                _save();
              }
              Navigator.pop(ctx);
            },
            child: Text(t(en, 'حفظ', 'Save')),
          ),
        ],
      ),
    );
  }

  void _setReportPeriod(String period) {
    final now = DateTime.now();
    setState(() {
      _period = period;
      _reportEnd = now;
      _reportStart = period == 'week'
          ? DateTime(now.year, now.month, now.day - 6)
          : period == 'year'
          ? DateTime(now.year, 1, 1)
          : DateTime(now.year, now.month, 1);
    });
  }

  Future<void> _choosePeriod() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 2),
      initialDateRange: DateTimeRange(
        start: _reportStart,
        end: _reportEnd.isAfter(now) ? now : _reportEnd,
      ),
    );
    if (picked != null)
      setState(() {
        _reportStart = picked.start;
        _reportEnd = picked.end;
        _period = 'custom';
      });
  }

  Future<void> _importSms({bool silent = false}) async {
    if (_importingSms || !_loaded) return;
    final enabledBanks = _banks.entries
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .toList();
    if (enabledBanks.isEmpty) {
      if (!silent)
        _snack(
          t(
            en,
            'فعّل بنكًا واحدًا على الأقل أولًا',
            'Enable at least one bank first',
          ),
        );
      return;
    }
    _importingSms = true;
    try {
      final hasPermission =
          await _channel.invokeMethod<bool>('hasSmsPermission') ?? false;
      if (!hasPermission) {
        if (!mounted) return;
        final accepted =
            await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                icon: const Icon(
                  Icons.verified_user_rounded,
                  color: _violet,
                  size: 32,
                ),
                title: Text(
                  t(en, 'استيراد رسائل البنك', 'Import bank messages'),
                ),
                content: Text(
                  t(
                    en,
                    'سيقرأ التطبيق رسائل البنوك التي فعّلتها فقط، ابتداءً من ${DateFormat('d MMM yyyy', 'ar').format(_budgetStart)}. تُحفظ العمليات على جهازك، وتُستبعد رسائل رموز التحقق.',
                    'Only messages from banks you enabled will be scanned, starting ${DateFormat('d MMM yyyy', 'en').format(_budgetStart)}. Transactions stay on this device; verification codes are skipped.',
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: Text(t(en, 'ليس الآن', 'Not now')),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: Text(t(en, 'متابعة', 'Continue')),
                  ),
                ],
              ),
            ) ??
            false;
        if (!accepted) return;
      }
      final start = DateTime(
        _budgetStart.year,
        _budgetStart.month,
        _budgetStart.day,
      ).millisecondsSinceEpoch;
      final end = _budgetEnd == null
          ? null
          : DateTime(
              _budgetEnd!.year,
              _budgetEnd!.month,
              _budgetEnd!.day,
              23,
              59,
              59,
              999,
            ).millisecondsSinceEpoch;
      final messages =
          await _channel.invokeListMethod<Map>('readBankSms', {
            'enabledBanks': enabledBanks,
            'startMillis': start,
            if (end != null) 'endMillis': end,
          }) ??
          [];
      var added = 0;
      final cutoff = DateTime.fromMillisecondsSinceEpoch(start);
      final endDate = end == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(end);
      for (final message in messages) {
        final body = (message['body'] ?? '').toString();
        final bank = (message['bank'] ?? '').toString();
        final id = (message['id'] ?? '').toString();
        final timestamp = (message['date'] as num?)?.toInt();
        if (_banks[bank] != true ||
            id.isEmpty ||
            timestamp == null ||
            _isOtp(body))
          continue;
        final transactionDate = DateTime.fromMillisecondsSinceEpoch(timestamp);
        if (transactionDate.isBefore(cutoff) ||
            (endDate != null && transactionDate.isAfter(endDate)))
          continue;
        if (_transactions.any((transaction) => transaction.note == id))
          continue;
        final parsed = _parseSms(body, bank, transactionDate);
        if (parsed != null) {
          _transactions.insert(0, parsed.copyWithNote(id));
          added++;
        }
      }
      if (added > 0) {
        await _save();
        if (mounted) setState(() {});
      }
      if (!silent && mounted)
        _snack(
          t(
            en,
            'تم استيراد $added عملية جديدة',
            'Imported $added new transactions',
          ),
        );
    } on PlatformException catch (error) {
      if (!silent && mounted)
        _snack(
          error.message ??
              t(
                en,
                'تعذر قراءة الرسائل على هذا الجهاز',
                'SMS reading is unavailable on this device',
              ),
        );
    } on MissingPluginException {
      if (!silent && mounted)
        _snack(
          t(
            en,
            'استيراد الرسائل متاح على Android بعد البناء',
            'SMS import is available on Android after building',
          ),
        );
    } finally {
      _importingSms = false;
    }
  }

  bool _isOtp(String value) {
    final lower = value.toLowerCase();
    return [
      'otp',
      'one-time',
      'verification',
      'verify',
      'رمز',
      'تحقق',
      'كود',
      'كلمة مرور مؤقتة',
      'temporary password',
      'security code',
      'رمز الدخول',
      'رمز التفعيل',
    ].any(lower.contains);
  }

  FinanceTransaction? _parseSms(
    String body,
    String bank,
    DateTime transactionDate,
  ) {
    final normalized = body
        .replaceAll('٠', '0')
        .replaceAll('١', '1')
        .replaceAll('٢', '2')
        .replaceAll('٣', '3')
        .replaceAll('٤', '4')
        .replaceAll('٥', '5')
        .replaceAll('٦', '6')
        .replaceAll('٧', '7')
        .replaceAll('٨', '8')
        .replaceAll('٩', '9')
        .replaceAll('٫', '.')
        .replaceAll('٬', ',');
    final amountMatch = RegExp(
      r'(?:SAR|ر\.س|ريال)\s*([0-9,]+(?:\.[0-9]{1,2})?)|(?:مبلغ|شراء|خصم|amount|purchase)\D{0,18}([0-9,]+(?:\.[0-9]{1,2})?)|([0-9,]+(?:\.[0-9]{1,2})?)\s*(?:SAR|ر\.س|ريال)',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (amountMatch == null) return null;
    final rawAmount =
        (amountMatch.group(1) ??
                amountMatch.group(2) ??
                amountMatch.group(3) ??
                '')
            .replaceAll(',', '');
    final amount = double.tryParse(rawAmount);
    if (amount == null || amount <= 0) return null;
    final card =
        RegExp(
          r'(?:\*{2,}|x{2,}|ending|بطاقة|من حساب).*?(\d{4})',
          caseSensitive: false,
        ).firstMatch(normalized)?.group(1) ??
        '';
    final merchant = RegExp(
      r'(?:at|merchant|from|لدى|عند|من متجر|في|من)\s+([^\n،.]+)',
      caseSensitive: false,
    ).firstMatch(normalized)?.group(1)?.trim();
    final title = merchant == null || merchant.isEmpty
        ? t(en, 'عملية بنكية مستوردة', 'Imported bank transaction')
        : merchant;
    final lower = normalized.toLowerCase();
    final isIncome = [
      'إيداع',
      'ايداع',
      'تم إضافة',
      'تم اضافة',
      'حوالة واردة',
      'راتب',
      'استلمت',
      'credited',
      'salary',
      'received',
    ].any(lower.contains);
    final isTransfer =
        !isIncome &&
        [
          'حوالة صادرة',
          'تحويل إلى',
          'تحويل الى',
          'transfer to',
          'sent to',
        ].any(lower.contains);
    final kind = isIncome
        ? 'income'
        : isTransfer
        ? 'transfer'
        : 'expense';
    final category = isIncome
        ? 'دخل'
        : isTransfer
        ? 'تحويل'
        : _guessCategory('$normalized $title');
    return FinanceTransaction(
      title: title,
      category: category,
      amount: amount,
      date: transactionDate,
      kind: kind,
      bank: bank,
      card: card,
    );
  }

  String _guessCategory(String value) {
    final lower = value.toLowerCase();
    if ([
      'مطعم',
      'قهوة',
      'كافيه',
      'تموين',
      'بقالة',
      'restaurant',
      'coffee',
      'grocery',
    ].any(lower.contains))
      return 'طعام ومقاهي';
    if ([
      'بنزين',
      'وقود',
      'محطة',
      'fuel',
      'petrol',
      'gas station',
    ].any(lower.contains))
      return 'بنزين ومواصلات';
    if ([
      'تسوق',
      'متجر',
      'مول',
      'shopping',
      'store',
      'market',
    ].any(lower.contains))
      return 'التسوق';
    if ([
      'فاتورة',
      'كهرباء',
      'مياه',
      'اتصالات',
      'bill',
      'utility',
      'telecom',
    ].any(lower.contains))
      return 'فواتير';
    if ([
      'سينما',
      'ترفيه',
      'مطعم ألعاب',
      'entertainment',
      'cinema',
    ].any(lower.contains))
      return 'ترفيه';
    return 'أخرى';
  }

  Future<void> _exportCsv() async {
    final rows = [
      [
        'Date',
        'Description',
        'Type',
        'Category',
        'Amount SAR',
        'Bank',
        'Card last 4',
      ],
      ..._reportTransactions.map(
        (x) => [
          DateFormat('yyyy-MM-dd HH:mm').format(x.date),
          x.title,
          x.kind,
          x.category,
          x.amount.toStringAsFixed(2),
          x.bank,
          x.card,
        ],
      ),
    ];
    final csv =
        '\uFEFF${rows.map((r) => r.map((v) => '"${v.replaceAll('"', '""')}"').join(',')).join('\r\n')}';
    final dir = Directory.systemTemp;
    final file = File(
      '${dir.path}/masroof-report-${DateTime.now().millisecondsSinceEpoch}.csv',
    );
    await file.writeAsString(csv, encoding: utf8);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: t(
          en,
          'تقرير المصروف الذكي بصيغة CSV المتوافقة مع Excel',
          'Masroof Smart report (Excel-compatible CSV)',
        ),
      ),
    );
  }

  double get _reportIncome => _reportTransactions
      .where((transaction) => transaction.kind == 'income')
      .fold<double>(0, (sum, transaction) => sum + transaction.amount);
  double get _reportNet => _reportIncome - _reportExpenses;

  Future<void> _exportPdf() async {
    final loadedFont = await rootBundle.load(
      'assets/fonts/NotoSansArabic-Regular.ttf',
    );
    final arabicFont = pw.Font.ttf(loadedFont);
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: arabicFont, bold: arabicFont),
    );
    final rtl = !en;
    final ink = PdfColor.fromHex('#172338');
    final muted = PdfColor.fromHex('#718096');
    final violet = PdfColor.fromHex('#7357F6');
    final mint = PdfColor.fromHex('#34C9A2');
    final navy = PdfColor.fromHex('#101A2D');
    final line = PdfColor.fromHex('#E7EAF1');
    final pale = PdfColor.fromHex('#F5F7FB');
    final locale = en ? 'en' : 'ar';
    final fmtDate = DateFormat('d MMM yyyy', locale);
    final reportDate = DateFormat('yyyy-MM-dd HH:mm', 'en');
    final expensesByCategory = <String, double>{};
    final expensesByBank = <String, double>{};
    final categoryRows = <MapEntry<String, double>>[];
    final bankRows = <MapEntry<String, double>>[];
    for (final transaction in _reportTransactions.where(
      (entry) => entry.kind == 'expense',
    )) {
      expensesByCategory.update(
        transaction.category,
        (value) => value + transaction.amount,
        ifAbsent: () => transaction.amount,
      );
      if (transaction.bank.isNotEmpty) {
        expensesByBank.update(
          transaction.bank,
          (value) => value + transaction.amount,
          ifAbsent: () => transaction.amount,
        );
      }
    }
    categoryRows.addAll(expensesByCategory.entries);
    categoryRows.sort((a, b) => b.value.compareTo(a.value));
    bankRows.addAll(expensesByBank.entries);
    bankRows.sort((a, b) => b.value.compareTo(a.value));
    pw.Widget text(
      String value, {
      double size = 9,
      PdfColor? color,
      bool bold = false,
      pw.TextAlign? align,
    }) => pw.Text(
      value,
      textDirection: rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
      textAlign: align ?? (rtl ? pw.TextAlign.right : pw.TextAlign.left),
      style: pw.TextStyle(
        font: arabicFont,
        fontSize: size,
        color: color ?? ink,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    );
    pw.Widget sectionTitle(String title) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 16, bottom: 8),
      child: pw.Row(
        children: [
          pw.Container(width: 4, height: 16, color: mint),
          pw.SizedBox(width: 7),
          pw.Expanded(child: text(title, size: 12, bold: true)),
        ],
      ),
    );
    pw.Widget stat(String title, String value, PdfColor accent) => pw.Expanded(
      child: pw.Container(
        margin: const pw.EdgeInsets.symmetric(horizontal: 4),
        padding: const pw.EdgeInsets.all(11),
        decoration: pw.BoxDecoration(
          color: pale,
          borderRadius: pw.BorderRadius.circular(10),
          border: pw.Border.all(color: line),
        ),
        child: pw.Column(
          crossAxisAlignment: rtl
              ? pw.CrossAxisAlignment.end
              : pw.CrossAxisAlignment.start,
          children: [
            text(title, size: 8, color: muted),
            pw.SizedBox(height: 5),
            text(value, size: 12, color: accent, bold: true),
          ],
        ),
      ),
    );
    pw.Widget detailRow(
      String label,
      String value, {
      bool emphasized = false,
    }) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 7, horizontal: 9),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: line, width: .6)),
      ),
      child: pw.Row(
        children: [
          pw.Expanded(
            child: text(
              label,
              size: 9,
              color: emphasized ? ink : muted,
              bold: emphasized,
            ),
          ),
          text(value, size: 9, bold: emphasized),
        ],
      ),
    );
    doc.addPage(
      pw.MultiPage(
        maxPages: 500,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(34, 36, 34, 42),
        theme: pw.ThemeData.withFont(base: arabicFont, bold: arabicFont),
        header: (_) => pw.Container(
          padding: const pw.EdgeInsets.only(bottom: 9),
          decoration: pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: line, width: .8)),
          ),
          child: pw.Row(
            children: [
              pw.Container(
                width: 20,
                height: 20,
                alignment: pw.Alignment.center,
                decoration: pw.BoxDecoration(
                  color: violet,
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Text(
                  'م',
                  style: pw.TextStyle(
                    font: arabicFont,
                    color: PdfColors.white,
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(width: 7),
              pw.Expanded(
                child: text(
                  t(en, 'المصروف الذكي', 'MASROOF SMART'),
                  size: 9,
                  bold: true,
                ),
              ),
              text(
                t(en, 'تقرير مالي خاص', 'PRIVATE FINANCIAL REPORT'),
                size: 7,
                color: muted,
              ),
            ],
          ),
        ),
        footer: (ctx) => pw.Container(
          padding: const pw.EdgeInsets.only(top: 8),
          decoration: pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: line, width: .7)),
          ),
          child: pw.Row(
            children: [
              pw.Expanded(
                child: text(
                  t(
                    en,
                    'تم إنشاء التقرير محليًا على جهازك',
                    'Generated locally on your device',
                  ),
                  size: 7,
                  color: muted,
                ),
              ),
              text(
                '${ctx.pageNumber} / ${ctx.pagesCount}',
                size: 8,
                color: muted,
              ),
            ],
          ),
        ),
        build: (_) => [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(20),
            decoration: pw.BoxDecoration(
              color: navy,
              borderRadius: pw.BorderRadius.circular(16),
            ),
            child: pw.Column(
              crossAxisAlignment: rtl
                  ? pw.CrossAxisAlignment.end
                  : pw.CrossAxisAlignment.start,
              children: [
                text(
                  t(en, 'ملخصك المالي', 'YOUR MONEY, IN FOCUS'),
                  size: 8,
                  color: PdfColor.fromHex('#AFA3FF'),
                  bold: true,
                ),
                pw.SizedBox(height: 7),
                text(
                  t(en, 'التقرير المالي', 'Financial report'),
                  size: 22,
                  color: PdfColors.white,
                  bold: true,
                ),
                pw.SizedBox(height: 5),
                text(
                  '${fmtDate.format(_reportStart)}  —  ${fmtDate.format(_reportEnd)}',
                  size: 10,
                  color: PdfColors.white,
                ),
                pw.SizedBox(height: 4),
                text(
                  t(
                    en,
                    'يشمل ${_reportTransactions.length} عملية ضمن الفترة المحددة',
                    'Includes ${_reportTransactions.length} transactions in this period',
                  ),
                  size: 8,
                  color: PdfColor.fromHex('#C7CDDA'),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 13),
          pw.Row(
            children: [
              stat(
                t(en, 'المصروفات', 'Expenses'),
                '${_reportExpenses.toStringAsFixed(2)} ${t(en, 'ر.س', 'SAR')}',
                violet,
              ),
              stat(
                t(en, 'الدخل', 'Income'),
                '${_reportIncome.toStringAsFixed(2)} ${t(en, 'ر.س', 'SAR')}',
                mint,
              ),
              stat(
                t(en, 'صافي الادخار', 'Net savings'),
                '${_reportNet.toStringAsFixed(2)} ${t(en, 'ر.س', 'SAR')}',
                _reportNet < 0 ? PdfColors.red : navy,
              ),
            ],
          ),
          sectionTitle(t(en, 'نظرة عامة', 'Overview')),
          detailRow(
            t(en, 'عدد العمليات', 'Transactions'),
            '${_reportTransactions.length}',
          ),
          detailRow(
            t(en, 'متوسط المصروف اليومي', 'Average daily spending'),
            '${(_reportExpenses / math.max(1, _reportEnd.difference(_reportStart).inDays + 1)).toStringAsFixed(2)} ${t(en, 'ر.س', 'SAR')}',
          ),
          detailRow(
            t(en, 'فترة التقرير', 'Report period'),
            '${fmtDate.format(_reportStart)} – ${fmtDate.format(_reportEnd)}',
          ),
          detailRow(
            t(en, 'بداية دورة الميزانية', 'Budget cycle starts'),
            fmtDate.format(_budgetStart),
          ),
          detailRow(
            t(en, 'حد الميزانية', 'Budget limit'),
            '${_monthlyBudget.toStringAsFixed(2)} ${t(en, 'ر.س', 'SAR')}',
          ),
          sectionTitle(t(en, 'المصروفات حسب الفئة', 'Spending by category')),
          if (expensesByCategory.isEmpty)
            detailRow(
              t(en, 'لا توجد مصروفات ضمن الفترة', 'No expenses in this period'),
              '—',
            )
          else
            ...categoryRows.map(
              (entry) => detailRow(
                en ? _translateCategory(entry.key) : entry.key,
                '${entry.value.toStringAsFixed(2)} ${t(en, 'ر.س', 'SAR')}',
              ),
            ),
          if (expensesByBank.isNotEmpty) ...[
            sectionTitle(t(en, 'المصروفات حسب البنك', 'Spending by bank')),
            ...bankRows.map(
              (entry) => detailRow(
                entry.key,
                '${entry.value.toStringAsFixed(2)} ${t(en, 'ر.س', 'SAR')}',
              ),
            ),
          ],
          sectionTitle(t(en, 'تفاصيل العمليات', 'Transaction details')),
          if (_reportTransactions.isEmpty)
            detailRow(
              t(
                en,
                'لا توجد عمليات في هذه الفترة',
                'No transactions in this period',
              ),
              '—',
            )
          else
            ..._reportTransactions.map((transaction) {
              final type = transaction.kind == 'income'
                  ? t(en, 'دخل', 'Income')
                  : transaction.kind == 'transfer'
                  ? t(en, 'تحويل', 'Transfer')
                  : transaction.kind == 'loan'
                  ? t(en, 'قرض', 'Loan')
                  : t(en, 'مصروف', 'Expense');
              final details = [
                if (transaction.bank.isNotEmpty) transaction.bank,
                if (transaction.card.isNotEmpty)
                  '${t(en, 'بطاقة', 'Card')} •••• ${transaction.card}',
                en
                    ? _translateCategory(transaction.category)
                    : transaction.category,
                type,
              ].join('  •  ');
              return pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 6),
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  color: pale,
                  borderRadius: pw.BorderRadius.circular(9),
                  border: pw.Border.all(color: line),
                ),
                child: pw.Column(
                  crossAxisAlignment: rtl
                      ? pw.CrossAxisAlignment.end
                      : pw.CrossAxisAlignment.start,
                  children: [
                    pw.Row(
                      children: [
                        pw.Expanded(
                          child: text(transaction.title, size: 10, bold: true),
                        ),
                        text(
                          '${transaction.amount.toStringAsFixed(2)} ${t(en, 'ر.س', 'SAR')}',
                          size: 10,
                          color: violet,
                          bold: true,
                        ),
                      ],
                    ),
                    pw.SizedBox(height: 4),
                    text(details, size: 7, color: muted),
                    pw.SizedBox(height: 3),
                    text(
                      reportDate.format(transaction.date),
                      size: 7,
                      color: muted,
                    ),
                  ],
                ),
              );
            }),
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#EAF9F5'),
              borderRadius: pw.BorderRadius.circular(9),
            ),
            child: text(
              t(
                en,
                'ملاحظة: هذا التقرير أُنشئ من البيانات المحفوظة محليًا، وقد لا يشمل الرسائل التي لم يتعرف التطبيق على صيغتها.',
                'Note: This report uses locally saved data and may not include messages whose format could not be recognized.',
              ),
              size: 7,
              color: muted,
            ),
          ),
        ],
      ),
    );
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename:
          'masroof-smart-report-${DateFormat('yyyy-MM-dd').format(_reportStart)}.pdf',
    );
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
  );

  Widget _banksPage() {
    final bankTotals = _banks.keys
        .map((bank) {
          final expenses = _transactions
              .where((x) => x.bank == bank && x.kind == 'expense')
              .toList();
          final total = expenses.fold<double>(
            0,
            (sum, transaction) => sum + transaction.amount,
          );
          return (bank: bank, expenses: expenses, total: total);
        })
        .where((item) => item.total > 0);
    return _scroll([
      _header(
        t(en, 'حسابات البنوك', 'Bank accounts'),
        subtitle: t(
          en,
          'اختر البنوك المسموح بقراءة رسائلها',
          'Choose which banks may be scanned',
        ),
      ),
      Container(
        margin: const EdgeInsets.fromLTRB(18, 0, 18, 12),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: _navy,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          t(
            en,
            'القراءة محلية على جهازك فقط. إيقاف البنك يمنع معالجة رسائله في التطبيق. لا ندعم رموز التحقق أو OTP.',
            'Messages are processed locally. Turning a bank off excludes its messages. OTPs are not imported.',
          ),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            height: 1.5,
          ),
        ),
      ),
      ..._banks.entries.map(
        (entry) => Container(
          margin: const EdgeInsets.fromLTRB(18, 4, 18, 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: SwitchListTile(
            value: entry.value,
            onChanged: (value) {
              setState(() => _banks[entry.key] = value);
              _save();
            },
            activeColor: _mint,
            title: Text(
              entry.key,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: _ink,
              ),
            ),
            subtitle: Text(
              entry.value
                  ? t(
                      en,
                      'مفعّل • تتم مراجعة رسائله عند الاستيراد',
                      'Enabled • messages checked on import',
                    )
                  : t(
                      en,
                      'متوقف • لن تتم معالجة رسائله',
                      'Off • messages ignored',
                    ),
              style: const TextStyle(fontSize: 10, color: _muted),
            ),
            secondary: const Icon(
              Icons.account_balance_rounded,
              color: _violet,
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      ...bankTotals.map(
        (item) => ListTile(
          title: Text(item.bank),
          subtitle: Text(
            '${item.expenses.length} ${t(en, 'عملية', 'transactions')}',
          ),
          trailing: Text(
            money(item.total),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ),
    ]);
  }
}

extension _CopyNote on FinanceTransaction {
  FinanceTransaction copyWithNote(String n) => FinanceTransaction(
    title: title,
    category: category,
    amount: amount,
    date: date,
    kind: kind,
    bank: bank,
    card: card,
    note: n,
  );
}

class DonutPainter extends CustomPainter {
  DonutPainter({required this.values, required this.colors, this.stroke = 11});
  final List<double> values;
  final List<Color> colors;
  final double stroke;
  @override
  void paint(Canvas c, Size s) {
    final center = Offset(s.width / 2, s.height / 2);
    final radius = math.min(s.width, s.height) / 2 - stroke;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final total = values.fold<double>(0, (a, b) => a + b);
    final base = Paint()
      ..color = const Color(0xFFEDF0F6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    c.drawCircle(center, radius, base);
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      if (sweep > 0)
        c.drawArc(
          rect,
          start,
          sweep - .035,
          false,
          Paint()
            ..color = colors[i % colors.length]
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round,
        );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant DonutPainter old) =>
      old.values != values || old.colors != colors;
}

class BarsPainter extends CustomPainter {
  BarsPainter({required this.values});
  final List<double> values;
  @override
  void paint(Canvas c, Size s) {
    final max = values.fold<double>(1, (a, b) => math.max(a, b).toDouble());
    final gap = 9.0;
    final w = (s.width - gap * (values.length - 1)) / values.length;
    final p = Paint()..color = const Color(0xFFE9EAF2);
    final hi = Paint()..color = _violet;
    for (var i = 0; i < values.length; i++) {
      final h = (s.height - 18) * values[i] / max;
      final x = i * (w + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, s.height - h - 16, w, h),
        const Radius.circular(7),
      );
      c.drawRRect(rect, i == values.length - 1 ? hi : p);
    }
    final tp = TextPainter(textDirection: ui.TextDirection.ltr);
    for (var i = 0; i < values.length; i++) {
      tp.text = TextSpan(
        text: ['M', 'T', 'W', 'T', 'F', 'S', 'S'][i],
        style: const TextStyle(fontSize: 9, color: _muted),
      );
      tp.layout();
      tp.paint(c, Offset(i * (w + gap) + (w - tp.width) / 2, s.height - 12));
    }
  }

  @override
  bool shouldRepaint(covariant BarsPainter old) => old.values != values;
}
