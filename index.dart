import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'firebase_options.dart'; // تأكد من استيراد ملف الخيارات الخاص بك

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // تهيئة Firebase بناءً على الكود الذي أرسلته
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  runApp(const MishwarApp());
}

class MishwarApp extends StatelessWidget {
  const MishwarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'نظام مشوارك - الكابتن',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'Segoe UI',
        primaryColor: const Color(0xFF5D3FD3),
        useMaterial3: true,
      ),
      // دعم اللغة العربية والاتجاه من اليمين لليسار
      home: const AuthWrapper(),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  Map? session;

  @override
  void initState() {
    super.initState();
    _checkLogin();
  }

  _checkLogin() async {
    final prefs = await SharedPreferences.getInstance();
    String? data = prefs.getString('mshwar_session');
    if (data != null) {
      setState(() => session = json.decode(data));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (session == null) {
      return LoginPage(onLogin: _checkLogin);
    }
    return MainPage(session: session!);
  }
}

// --- صفحة تسجيل الدخول ---
class LoginPage extends StatefulWidget {
  final VoidCallback onLogin;
  const LoginPage({super.key, required this.onLogin});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _handleLogin() async {
    setState(() => _isLoading = true);
    final db = FirebaseDatabase.instance.ref('pricing');
    
    try {
      final snapshot = await db.get();
      bool found = false;

      if (snapshot.exists) {
        Map areas = snapshot.value as Map;
        areas.forEach((areaKey, areaData) {
          // 1. فحص السائقين
          if (areaData['drivers'] != null) {
            Map drivers = areaData['drivers'];
            drivers.forEach((id, drData) {
              if (drData['password'].toString() == _passwordController.text) {
                _saveAndLogin(areaKey, id, drData, 'driver');
                found = true;
              }
            });
          }

          // 2. فحص المحلات (ماركت/صيدلية)
          if (!found && areaData['shopSettings'] != null) {
            Map shops = areaData['shopSettings'];
            shops.forEach((type, shopData) {
              if (shopData['phone'].toString() == _passwordController.text) {
                _saveAndLogin(areaKey, type, shopData, type);
                found = true;
              }
            });
          }
        });
      }

      if (!found) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("الكود غير صحيح")));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("خطأ في الاتصال: $e")));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  _saveAndLogin(String area, String id, Map data, String role) async {
    final prefs = await SharedPreferences.getInstance();
    Map userSession = {
      'role': role,
      'id': id,
      'area': area,
      'name': data['name'],
      'phone': data['phone'] ?? '',
    };
    await prefs.setString('mshwar_session', json.encode(userSession));
    widget.onLogin();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(25),
          child: Container(
            padding: const EdgeInsets.all(30),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(30),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 20)],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.delivery_dining, size: 80, color: Color(0xFF5D3FD3)),
                const SizedBox(height: 20),
                const Text("دخول الكابتن والمحلات", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 25),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: "أدخل الكود الخاص بك",
                    filled: true,
                    fillColor: Colors.grey[100],
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 20),
                _isLoading 
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5D3FD3),
                        minimumSize: const Size(double.infinity, 55),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      ),
                      child: const Text("دخول للنظام 🚀", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- الصفحة الرئيسية ---
class MainPage extends StatefulWidget {
  final Map session;
  const MainPage({super.key, required this.session});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  String currentTab = 'مشوار';
  List allOrders = [];
  double totalDebt = 0.0;

  @override
  void initState() {
    super.initState();
    _initDataStream();
  }

  _initDataStream() {
    final area = widget.session['area'];
    
    // مراقبة المديونية للسائقين فقط
    if (widget.session['role'] == 'driver') {
      FirebaseDatabase.instance.ref('pricing/$area/drivers/${widget.session['id']}/totalDebt')
          .onValue.listen((event) {
        if (mounted) {
          setState(() => totalDebt = double.tryParse(event.snapshot.value.toString()) ?? 0.0);
        }
      });
    }

    // مراقبة الطلبات في المنطقة
    FirebaseDatabase.instance.ref('orders/$area').onValue.listen((event) {
      if (event.snapshot.exists && mounted) {
        Map data = event.snapshot.value as Map;
        List temp = [];
        data.forEach((key, val) => temp.add({'key': key, ...val}));
        // ترتيب التنازلي حسب الوقت
        temp.sort((a, b) => (b['time'] ?? 0).compareTo(a['time'] ?? 0));
        setState(() => allOrders = temp);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    bool isDriver = widget.session['role'] == 'driver';

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF5D3FD3),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.session['name'], style: const TextStyle(fontSize: 16)),
            if (isDriver) Text("المديونية: ${totalDebt.toStringAsFixed(1)} ج", style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: Column(
        children: [
          if (isDriver) _buildDriverTabs(),
          Expanded(child: _buildListContent()),
        ],
      ),
    );
  }

  Widget _buildDriverTabs() {
    final tabs = ['مشوار', 'ماركت', 'صيدلية', 'طرد', 'سجل'];
    return Container(
      height: 60,
      margin: const EdgeInsets.symmetric(vertical: 10),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        children: tabs.map((t) => _tabItem(t)).toList(),
      ),
    );
  }

  Widget _tabItem(String title) {
    bool active = currentTab == title;
    // حساب العداد (Notifications)
    int count = allOrders.where((o) {
      if (!o['type'].toString().contains(title)) return false;
      if (title == 'مشوار' || title == 'طرد') return o['status'] == 'pending';
      return o['status'] == 'prepared';
    }).length;

    return GestureDetector(
      onTap: () => setState(() => currentTab = title),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 5),
        padding: const EdgeInsets.symmetric(horizontal: 15),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF5D3FD3) : Colors.white,
          borderRadius: BorderRadius.circular(15),
        ),
        alignment: Alignment.center,
        child: Row(
          children: [
            Text(title, style: TextStyle(color: active ? Colors.white : Colors.black54, fontWeight: FontWeight.bold)),
            if (count > 0 && title != 'سجل') ...[
              const SizedBox(width: 5),
              CircleAvatar(radius: 9, backgroundColor: Colors.red, child: Text(count.toString(), style: const TextStyle(color: Colors.white, fontSize: 10))),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildListContent() {
    List filtered = [];
    if (widget.session['role'] == 'driver') {
      // إذا كان هناك طلب نشط حالياً (تم قبوله ولم ينتهِ)
      var active = allOrders.where((o) => o['status'] == 'picked_up' && o['driverId'] == widget.session['id']);
      if (active.isNotEmpty) return ListView(children: [_orderCard(active.first, isActive: true)]);

      if (currentTab == 'سجل') {
        filtered = allOrders.where((o) => o['status'] == 'completed' && o['driverId'] == widget.session['id']).toList();
      } else {
        filtered = allOrders.where((o) => o['type'].toString().contains(currentTab) && 
                 ((currentTab == 'مشوار' || currentTab == 'طرد') ? o['status'] == 'pending' : o['status'] == 'prepared')).toList();
      }
    } else {
      // واجهة المحلات
      String typeKey = widget.session['role'] == 'market' ? 'طلب ماركت' : 'طلب صيدلية';
      filtered = allOrders.where((o) => o['type'] == typeKey && o['status'] == 'pending').toList();
    }

    if (filtered.isEmpty) return const Center(child: Text("لا توجد طلبات حالياً"));

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) => _orderCard(filtered[index]),
    );
  }

  Widget _orderCard(Map o, {bool isActive = false}) {
    bool isHistory = o['status'] == 'completed';
    bool isShop = widget.session['role'] != 'driver';
    
    // الألوان
    Color mainColor = const Color(0xFF5D3FD3);
    if (o['type'].toString().contains('ماركت')) mainColor = const Color(0xFFF59E0B);
    if (o['type'].toString().contains('صيدلية')) mainColor = const Color(0xFF0EA5E9);
    if (o['type'].toString().contains('طرد')) mainColor = const Color(0xFFEF4444);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border(right: BorderSide(color: mainColor, width: 6)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: mainColor, borderRadius: BorderRadius.circular(8)),
                child: Text(o['type'], style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              if (!isShop) Text("${o['price']} ج", style: const TextStyle(color: Colors.green, fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 5),
          Text(DateFormat('hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(o['time'] ?? 0)), style: const TextStyle(color: Colors.grey, fontSize: 11)),
          
          if (isShop) ...[
             const SizedBox(height: 10),
             Container(
               width: double.infinity,
               padding: const EdgeInsets.all(12),
               decoration: BoxDecoration(color: Colors.amber[50], borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.amber.shade200, style: BorderStyle.none)),
               child: Text("المحتوى: ${o['details'] ?? 'تجهيز طلب'}", style: TextStyle(color: Colors.amber[900])),
             )
          ],

          const SizedBox(height: 15),
          _routeItem(Icons.store, "من:", o['from'] ?? "أجا", mainColor),
          const Padding(padding: EdgeInsets.only(right: 10), child: SizedBox(height: 10, child: VerticalDivider(width: 2, color: Colors.grey))),
          _routeItem(Icons.location_on, "إلى:", o['to'] ?? "", Colors.green),

          const SizedBox(height: 15),
          if (isActive || isHistory || isShop) ...[
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => launchUrl(Uri.parse("tel:${o['phone']}")),
                    icon: const Icon(Icons.phone),
                    label: const Text("اتصال"),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                  ),
                ),
                if (o['receiverPhone'] != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => launchUrl(Uri.parse("tel:${o['receiverPhone']}")),
                      icon: const Icon(Icons.person),
                      label: const Text("المستلم"),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                    ),
                  ),
                ]
              ],
            ),
            const SizedBox(height: 10),
          ],

          // أزرار الأكشن
          if (!isHistory && !isActive && !isShop) 
            _actionBtn("قبول وحجز ✅", mainColor, () => _updateStatus(o['key'], 'picked_up')),
          
          if (isActive) 
            _actionBtn("تم التوصيل ✅", Colors.green, () => _completeOrder(o['key'], o['commission'])),
          
          if (isShop)
            _actionBtn("تم التجهيز (إرسال للسائق) 🚀", mainColor, () => _updateStatus(o['key'], 'prepared')),
        ],
      ),
    );
  }

  Widget _routeItem(IconData icon, String label, String val, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold)),
        const SizedBox(width: 10),
        Expanded(child: Text(val, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
      ],
    );
  }

  Widget _actionBtn(String txt, Color color, VoidCallback press) {
    return ElevatedButton(
      onPressed: press,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(txt, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
    );
  }

  _updateStatus(String key, String status) {
    Map<String, dynamic> updates = {'status': status};
    if (status == 'prepared') updates['from'] = widget.session['name'];
    if (status == 'picked_up') {
      updates['driverId'] = widget.session['id'];
      updates['driverName'] = widget.session['name'];
      updates['driverPhone'] = widget.session['phone'];
    }
    FirebaseDatabase.instance.ref('orders/${widget.session['area']}/$key').update(updates);
  }

  _completeOrder(String key, dynamic comm) async {
    final area = widget.session['area'];
    await FirebaseDatabase.instance.ref('orders/$area/$key').update({'status': 'completed'});
    
    // تحديث المديونية
    final debtRef = FirebaseDatabase.instance.ref('pricing/$area/drivers/${widget.session['id']}/totalDebt');
    final snap = await debtRef.get();
    double current = double.tryParse(snap.value.toString()) ?? 0.0;
    double commission = double.tryParse(comm.toString()) ?? 0.0;
    debtRef.set((current + commission).toStringAsFixed(1));
  }

  _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (mounted) Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (c) => const AuthWrapper()));
  }
}
