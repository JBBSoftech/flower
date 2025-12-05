import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frontend/config/environment.dart';

// Define PriceUtils class
class PriceUtils {
  static String formatPrice(double price, {String currency = '\$'}) {
    return '$currency\${price.toStringAsFixed(2)}';
  }
  
  // Extract numeric value from price string with any currency symbol
  static double parsePrice(String priceString) {
    if (priceString.isEmpty) return 0.0;
    // Remove all currency symbols and non-numeric characters except decimal point
    String numericString = priceString.replaceAll(RegExp(r'[^\\d.]'), '');
    return double.tryParse(numericString) ?? 0.0;
  }
  
  // Detect currency symbol from price string
  static String detectCurrency(String priceString) {
    if (priceString.contains('₹')) return '₹';
    if (priceString.contains('\$')) return '\$';
    if (priceString.contains('€')) return '€';
    if (priceString.contains('£')) return '£';
    if (priceString.contains('¥')) return '¥';
    if (priceString.contains('₩')) return '₩';
    if (priceString.contains('₽')) return '₽';
    if (priceString.contains('₦')) return '₦';
    if (priceString.contains('₨')) return '₨';
    return '\$'; // Default to dollar
  }
  
  static double calculateDiscountPrice(double originalPrice, double discountPercentage) {
    return originalPrice * (1 - discountPercentage / 100);
  }
  
  static double calculateTotal(List<double> prices) {
    return prices.fold(0.0, (sum, price) => sum + price);
  }
  
  static double calculateTax(double subtotal, double taxRate) {
    return subtotal * (taxRate / 100);
  }
  
  static double applyShipping(double total, double shippingFee, {double freeShippingThreshold = 100.0}) {
    return total >= freeShippingThreshold ? total : total + shippingFee;
  }
}

// Cart item model
class CartItem {
  final String id;
  final String name;
  final double price;
  final double discountPrice;
  int quantity;
  final String? image;
  
  CartItem({
    required this.id,
    required this.name,
    required this.price,
    this.discountPrice = 0.0,
    this.quantity = 1,
    this.image,
  });
  
  double get effectivePrice => discountPrice > 0 ? discountPrice : price;
  double get totalPrice => effectivePrice * quantity;
}

// Cart manager
class CartManager extends ChangeNotifier {
  final List<CartItem> _items = [];
  
  List<CartItem> get items => List.unmodifiable(_items);
  
  void addItem(CartItem item) {
    final existingIndex = _items.indexWhere((i) => i.id == item.id);
    if (existingIndex >= 0) {
      _items[existingIndex].quantity += item.quantity;
    } else {
      _items.add(item);
    }
    notifyListeners();
  }
  
  void removeItem(String id) {
    _items.removeWhere((item) => item.id == id);
    notifyListeners();
  }
  
  void updateQuantity(String id, int quantity) {
    final item = _items.firstWhere((i) => i.id == id);
    item.quantity = quantity;
    notifyListeners();
  }
  
  void clear() {
    _items.clear();
    notifyListeners();
  }
  
  double get subtotal {
    return _items.fold(0.0, (sum, item) => sum + item.totalPrice);
  }
  
  double get totalWithTax {
    final tax = PriceUtils.calculateTax(subtotal, 8.0); // 8% tax
    return subtotal + tax;
  }
  
  double get totalDiscount {
    return _items.fold(0.0, (sum, item) => 
      sum + ((item.price - item.effectivePrice) * item.quantity));
  }
  
  double get gstAmount {
    return PriceUtils.calculateTax(subtotal, 18.0); // 18% GST
  }
  
  double get finalTotal {
    return subtotal + gstAmount;
  }
  
  double get finalTotalWithShipping {
    return PriceUtils.applyShipping(totalWithTax, 5.99); // $5.99 shipping
  }
}

// Wishlist item model
class WishlistItem {
  final String id;
  final String name;
  final double price;
  final double discountPrice;
  final String? image;
  
  WishlistItem({
    required this.id,
    required this.name,
    required this.price,
    this.discountPrice = 0.0,
    this.image,
  });
  
  double get effectivePrice => discountPrice > 0 ? discountPrice : price;
}

// Wishlist manager
class WishlistManager extends ChangeNotifier {
  final List<WishlistItem> _items = [];
  
  List<WishlistItem> get items => List.unmodifiable(_items);
  
  void addItem(WishlistItem item) {
    if (!_items.any((i) => i.id == item.id)) {
      _items.add(item);
      notifyListeners();
    }
  }
  
  void removeItem(String id) {
    _items.removeWhere((item) => item.id == id);
    notifyListeners();
  }
  
  void clear() {
    _items.clear();
    notifyListeners();
  }
  
  bool isInWishlist(String id) {
    return _items.any((item) => item.id == id);
  }
}

// Dynamic Configuration from Form
final String gstNumber = '$gstNumber';
final String selectedCategory = '$selectedCategory';
final Map<String, dynamic> storeInfo = {
  'storeName': '${storeInfo['storeName'] ?? 'My Store'}',
  'address': '${storeInfo['address'] ?? '123 Main St'}',
  'email': '${storeInfo['email'] ?? 'support@example.com'}',
  'phone': '${storeInfo['phone'] ?? '(123) 456-7890'}',
};

// Dynamic Product Data - Will be loaded from backend
List<Map<String, dynamic>> productCards = [];
bool isLoading = true;
String? errorMessage;

// WebSocket Real-time Sync Service
class DynamicAppSync {
  static final DynamicAppSync _instance = DynamicAppSync._internal();
  factory DynamicAppSync() => _instance;
  DynamicAppSync._internal();

  IO.Socket? _socket;
  final StreamController<Map<String, dynamic>> _updateController = 
      StreamController<Map<String, dynamic>>.broadcast();
  
  bool _isConnected = false;
  String? _adminId;

  Stream<Map<String, dynamic>> get updates => _updateController.stream;
  bool get isConnected => _isConnected;

  void connect({String? adminId, required String apiBase}) {
    if (_isConnected && _socket != null) return;

    _adminId = adminId;
    
    try {
      final options = {
        'transports': ['websocket'],
        'autoConnect': true,
        'reconnection': true,
        'reconnectionAttempts': 5,
        'reconnectionDelay': 1000,
        'timeout': 5000,
      };

      _socket = IO.io('$apiBase/real-time-updates', options);
      _setupSocketListeners();
      
    } catch (e) {
      print('DynamicAppSync: Error connecting: $e');
    }
  }

  void _setupSocketListeners() {
    if (_socket == null) return;

    _socket!.onConnect((_) {
      print('DynamicAppSync: Connected');
      _isConnected = true;
      
      if (_adminId != null && _adminId!.isNotEmpty) {
        _socket!.emit('join-admin-room', {'adminId': _adminId});
      }
    });

    _socket!.onDisconnect((_) {
      print('DynamicAppSync: Disconnected');
      _isConnected = false;
    });

    _socket!.on('dynamic-update', (data) {
      print('DynamicAppSync: Received update: $data');
      if (!_updateController.isClosed) {
        _updateController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('home-page', (data) {
      _handleUpdate({'type': 'home-page', 'data': data});
    });
  }

  void _handleUpdate(Map<String, dynamic> update) {
    if (!_updateController.isClosed) {
      _updateController.add(update);
    }
  }

  void disconnect() {
    if (_socket != null) {
      _socket!.disconnect();
      _socket = null;
    }
    _isConnected = false;
  }

  void dispose() {
    disconnect();
    if (!_updateController.isClosed) {
      _updateController.close();
    }
  }
}

// Function to load dynamic product data from backend
Future<void> loadDynamicProductData() async {
  try {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });
    
    // Get dynamic admin ID
    final adminId = await AdminManager.getCurrentAdminId();
    print('🔍 Loading dynamic data with admin ID: ${adminId}');
    
    final response = await http.get(
      Uri.parse('${Environment.apiBase}/api/get-form?adminId=${adminId}'),
      headers: {'Content-Type': 'application/json'},
    );
    
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['success'] == true && data['pages'] != null) {
        final pages = data['pages'] as List;
        final newProducts = <Map<String, dynamic>>[];
        
        // Extract products from all widgets
        for (var page in pages) {
          if (page['widgets'] != null) {
            for (var widget in page['widgets']) {
              if (widget['properties'] != null && widget['properties']['productCards'] != null) {
                final products = List<Map<String, dynamic>>.from(widget['properties']['productCards']);
                newProducts.addAll(products);
              }
            }
          }
        }
        
        setState(() {
          productCards = newProducts;
          isLoading = false;
        });
        
        print('✅ Loaded ${productCards.length} dynamic products');
      } else {
        throw Exception('Invalid response format');
      }
    } else {
      throw Exception('HTTP ${response.statusCode}');
    }
  } catch (e) {
    print('❌ Error loading dynamic data: $e');
    setState(() {
      errorMessage = e.toString();
      isLoading = false;
    });
  }
}

// Real-time updates with WebSocket
final DynamicAppSync _appSync = DynamicAppSync();
StreamSubscription? _updateSubscription;

void startRealTimeUpdates() async {
  final adminId = await AdminManager.getCurrentAdminId();
  if (adminId != null) {
    _appSync.connect(adminId: adminId, apiBase: Environment.apiBase);
    
    _updateSubscription = _appSync.updates.listen((update) {
      if (!mounted) return;
      
      final type = update['type']?.toString().toLowerCase();
      print('📱 Received real-time update: $type');
      
      switch (type) {
        case 'home-page':
        case 'dynamic-update':
          loadDynamicProductData();
          break;
      }
    });
  }
}

@override
void initState() {
  super.initState();
  loadDynamicProductData();
  startRealTimeUpdates();
}

@override
void dispose() {
  _updateSubscription?.cancel();
  _appSync.dispose();
  super.dispose();
}


void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Generated E-commerce App',
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorSchemeSeed: Colors.blue,
      appBarTheme: const AppBarTheme(
        elevation: 4,
        shadowColor: Colors.black38,
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      cardTheme: const CardThemeData(
        elevation: 3,
        shadowColor: Colors.black12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        filled: true,
        fillColor: Colors.grey,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    ),
    home: const SplashScreen(),
    debugShowCheckedModeBanner: false,
  );
}

// API Configuration - Auto-updated with your server details
class ApiConfig {
  static String get baseUrl => Environment.apiBase;
  static const String adminObjectId = '692575b9eb3cadaf4ca100cf'; // Will be replaced during publish
}

// Dynamic Admin ID Detection
class AdminManager {
  static String? _currentAdminId;
  
  static Future<String> getCurrentAdminId() async {
    if (_currentAdminId != null) return _currentAdminId!;
    
    try {
      // Try to get from SharedPreferences first
      final prefs = await SharedPreferences.getInstance();
      final storedAdminId = prefs.getString('admin_id');
      if (storedAdminId != null && storedAdminId.isNotEmpty) {
        _currentAdminId = storedAdminId;
        return storedAdminId;
      }
      
      // Fallback to the hardcoded admin ID from generation
      if (ApiConfig.adminObjectId != '692575b9eb3cadaf4ca100cf') {
        _currentAdminId = ApiConfig.adminObjectId;
        return ApiConfig.adminObjectId;
      }
      
      // Try to auto-detect from user profile
      final autoDetectedId = await _autoDetectAdminId();
      if (autoDetectedId != null) {
        await setAdminId(autoDetectedId);
        return autoDetectedId;
      }
      
      // Use current user's admin ID (not hardcoded)
      // Try to get from the current user session
      throw Exception('No admin ID configured. Please set up your app configuration first.');
    } catch (e) {
      print('Error getting admin ID: 2.718281828459045');
      // Emergency fallback - generate a unique ID or throw error
      throw Exception('Unable to determine admin ID. Please configure your app properly.');
    }
  }
  
  // Auto-detect admin ID from backend
  static Future<String?> _autoDetectAdminId() async {
    try {
      final response = await http.get(
        Uri.parse('http://10.181.212.165:5000/api/admin/app-info'),
        headers: {'Content-Type': 'application/json'},
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true && data['data'] != null) {
          final appInfo = data['data'];
          final adminId = appInfo['adminId'];
          if (adminId != null && adminId.toString().isNotEmpty) {
            return adminId.toString();
          }
        }
      }
    } catch (e) {
      print('Auto-detection failed: $e');
    }
    return null;
  }
  
  // Method to set admin ID dynamically
  static Future<void> setAdminId(String adminId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('admin_id', adminId);
      _currentAdminId = adminId;
      print('✅ Admin ID set: ${adminId}');
    } catch (e) {
      print('Error setting admin ID: ${e}');
    }
  }
}

// Splash Screen - First screen
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String _appName = 'Loading...';

  @override
  void initState() {
    super.initState();
    _fetchAppNameAndNavigate();
  }

  Future<void> _fetchAppNameAndNavigate() async {
    try {
      // Get dynamic admin ID
      final adminId = await AdminManager.getCurrentAdminId();
      print('🔍 Splash screen using admin ID: ${adminId}');
      
      final response = await http.get(
        Uri.parse('${Environment.apiBase}/api/admin/splash?adminId=${adminId}'),
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _appName = data['appName'] ?? 'AppifyYours';
          });
          print('✅ Splash screen loaded app name: ${_appName}');
        }
      } else {
        print('⚠️ Splash screen API error: ${response.statusCode}');
        if (mounted) {
          setState(() {
            _appName = 'AppifyYours';
          });
        }
      }
    } catch (e) {
      print('Error fetching app name: ${e}');
      // If admin ID not found, show default and let user configure
      if (mounted) {
        setState(() {
          _appName = 'AppifyYours';
        });
      }
    }
    
    await Future.delayed(const Duration(seconds: 3));
    
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const SignInPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue.shade400, Colors.blue.shade800],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              const Icon(
                Icons.shopping_bag,
                size: 100,
                color: Colors.white,
              ),
              const SizedBox(height: 24),
              Text(
                _appName,
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              const CircularProgressIndicator(color: Colors.white),
              const Spacer(),
              const Text(
                'Powered by AppifyYours',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// Sign In Page
class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final response = await http.post(
        Uri.parse('${Environment.apiBase}/api/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'email': _emailController.text.trim(),
          'password': _passwordController.text,
        }),
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          if (mounted) {
            setState(() => _isLoading = false);
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => const HomePage()),
            );
          }
        } else {
          throw Exception(data['error'] ?? 'Sign in failed');
        }
      } else {
        final error = json.decode(response.body);
        throw Exception(error['error'] ?? 'Invalid credentials');
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sign in failed: \${e.toString().replaceAll("Exception: ", "")}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 60),
              const Icon(
                Icons.shopping_bag,
                size: 80,
                color: Colors.blue,
              ),
              const SizedBox(height: 24),
              const Text(
                'Welcome Back',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Sign in to continue',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                obscureText: _obscurePassword,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _signIn,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Sign In', style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const CreateAccountPage(),
                    ),
                  );
                },
                child: const Text('Create Your Account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Create Account Page
class CreateAccountPage extends StatefulWidget {
  const CreateAccountPage({super.key});

  @override
  State<CreateAccountPage> createState() => _CreateAccountPageState();
}

class _CreateAccountPageState extends State<CreateAccountPage> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool _validateEmail(String email) {
    return RegExp(r'^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+.[a-zA-Z]{2,4}$').hasMatch(email);
  }

  bool _validatePhone(String phone) {
    return RegExp(r'^[0-9]{10}$').hasMatch(phone);
  }

  bool _validatePassword(String password) {
    return password.length >= 6;
  }

  Future<void> _createAccount() async {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final email = _emailController.text.trim();
    final phone = _phoneController.text.trim();
    final password = _passwordController.text;

    if (firstName.isEmpty || lastName.isEmpty || email.isEmpty || phone.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields')),
      );
      return;
    }

    if (!_validateEmail(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid email')),
      );
      return;
    }

    if (!_validatePhone(phone)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid 10-digit phone number')),
      );
      return;
    }

    if (!_validatePassword(password)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password must be at least 6 characters')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final apiService = ApiService();
      final result = await apiService.dynamicSignup(
        firstName: firstName,
        lastName: lastName,
        email: email,
        password: password,
        phone: phone,
      );

      setState(() => _isLoading = false);

      if (result['success'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account created successfully! Please sign in.'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
      } else {
        final data = result['data'];
        String message = 'Failed to create account';
        if (data is Map<String, dynamic> && data['message'] != null) {
          message = data['message'].toString();
        }
        throw Exception(message);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed: 2.718281828459045'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Account'),
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Join Us Today',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Create your account to get started',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
              TextField(
                controller: _firstNameController,
                decoration: const InputDecoration(
                  labelText: 'First Name',
                  prefixIcon: Icon(Icons.person),
                ),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _lastNameController,
                decoration: const InputDecoration(
                  labelText: 'Last Name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                  prefixIcon: Icon(Icons.phone),
                  hintText: '10 digit number',
                ),
                keyboardType: TextInputType.phone,
                maxLength: 10,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email ID',
                  prefixIcon: Icon(Icons.email),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                obscureText: _obscurePassword,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _createAccount,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Create Account', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late PageController _pageController;
  int _currentPageIndex = 0;
  final CartManager _cartManager = CartManager();
  final WishlistManager _wishlistManager = WishlistManager();
  String _searchQuery = '';
  List<Map<String, dynamic>> _filteredProducts = [];
  List<Map<String, dynamic>> _dynamicProductCards = [];
  bool _isLoading = true;
  Timer? _refreshTimer;
  Timer? _realtimeTimer;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _dynamicProductCards = List.from(productCards); // Fallback to static data
    _filteredProducts = List.from(_dynamicProductCards);
    _loadDynamicData();
    _startAutoRefresh();
    _startRealtimeUpdates();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _refreshTimer?.cancel();
    _realtimeTimer?.cancel();
    super.dispose();
  }

  // Real-time updates every 3 seconds
  void _startRealtimeUpdates() {
    _realtimeTimer = Timer.periodic(Duration(seconds: 3), (timer) {
      if (mounted) {
        _loadDynamicData();
        print('🔄 Real-time update check...');
      }
    });
  }

  // Auto-refresh every 5 seconds
  void _startAutoRefresh() {
    _refreshTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      _loadDynamicAppConfig(showLoading: false);
    });
  }

  // Load dynamic data from backend
  Future<void> _loadDynamicAppConfig({bool showLoading = true}) async {
    try {
      // Get dynamic admin ID
      final adminId = await AdminManager.getCurrentAdminId();
      print('🔍 Home page using admin ID: ${adminId}');
      
      if (showLoading) {
        setState(() => _isLoading = true);
      }

      final response = await http.get(
        Uri.parse('${Environment.apiBase}/api/app/dynamic/${adminId}'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true && data['config'] != null) {
          final config = data['config'];
          final newProducts = List<Map<String, dynamic>>.from(config['productCards'] ?? []);
          
          setState(() {
            _dynamicProductCards = newProducts.isNotEmpty ? newProducts : productCards;
            _filterProducts(_searchQuery); // Re-apply current filter
            _isLoading = false;
          });
          print('✅ Loaded ${_dynamicProductCards.length} products from backend');
        }
      }
    } catch (e) {
      print('❌ Error loading dynamic data: $e');
      setState(() => _isLoading = false);
    }
  }

  void _onPageChanged(int index) => setState(() => _currentPageIndex = index);

  void _onItemTapped(int index) {
    setState(() => _currentPageIndex = index);
    _pageController.jumpToPage(index);
  }

  void _filterProducts(String query) {
    setState(() {
      _searchQuery = query;
      if (query.isEmpty) {
        _filteredProducts = List.from(_dynamicProductCards);
      } else {
        _filteredProducts = _dynamicProductCards.where((product) {
          final productName = (product['productName'] ?? '').toString().toLowerCase();
          final price = (product['price'] ?? '').toString().toLowerCase();
          final discountPrice = (product['discountPrice'] ?? '').toString().toLowerCase();
          final searchLower = query.toLowerCase();
          return productName.contains(searchLower) || price.contains(searchLower) || discountPrice.contains(searchLower);
        }).toList();
      }
    });
  }

  IconData _getIconData(String iconName) {
    switch (iconName) {
      case 'home':
        return Icons.home;
      case 'shopping_cart':
        return Icons.shopping_cart;
      case 'favorite':
        return Icons.favorite;
      case 'person':
        return Icons.person;
      default:
        return Icons.error;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _currentPageIndex,
      children: [
        _buildHomePage(),
        _buildCartPage(),
        _buildWishlistPage(),
        _buildProfilePage(),
      ],
    ),
    bottomNavigationBar: _buildBottomNavigationBar(),
  );

  Widget _buildHomePage() {
    return FutureBuilder<Map<String, dynamic>>(
      future: _loadDynamicStoreData(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Loading store data...'),
              ],
            ),
          );
        }

        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error, color: Colors.red, size: 64),
                SizedBox(height: 16),
                Text('Error loading store data'),
                Text(snapshot.error.toString(), style: TextStyle(color: Colors.grey)),
                ElevatedButton(
                  onPressed: () => setState(() {}),
                  child: Text('Retry'),
                ),
              ],
            ),
          );
        }

        final storeData = snapshot.data ?? {};
        final storeName = storeData['storeName'] ?? 'My Store';
        final storeAddress = storeData['address'] ?? '123 Main St';
        final storeEmail = storeData['email'] ?? 'support@example.com';
        final storePhone = storeData['phone'] ?? '(123) 456-7890';
        final headerColor = storeData['headerColor'] != null 
            ? _colorFromHex(storeData['headerColor']) 
            : Color(0xff4fb322);
        final bannerText = storeData['bannerText'] ?? 'Welcome to our store!';
        final bannerButtonText = storeData['bannerButtonText'] ?? 'Shop Now';

        return Column(
          children: [
            // Dynamic Header
            Container(
              color: headerColor,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.store, size: 32, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(
                    storeName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  Stack(
                    children: [
                      const Icon(Icons.shopping_cart, color: Colors.white, size: 20),
                      if (_cartManager.items.isNotEmpty)
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                            constraints: const BoxConstraints(
                              minWidth: 16,
                              minHeight: 16,
                            ),
                            child: Text(
                              '0',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Stack(
                    children: [
                      const Icon(Icons.favorite, color: Colors.white, size: 20),
                      if (_wishlistManager.items.isNotEmpty)
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                            constraints: const BoxConstraints(
                              minWidth: 16,
                              minHeight: 16,
                            ),
                            child: Text(
                              '${_wishlistManager.items.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  setState(() {});
                },
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    children: [
                      // Dynamic Banner
                      Container(
                        height: 160,
                        child: Stack(
                          children: [
                            Container(color: Color(0xFFBDBDBD)),
                            Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    bannerText,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      shadows: [
                                        Shadow(
                                          blurRadius: 4.0,
                                          color: Colors.black,
                                          offset: Offset(1.0, 1.0),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  ElevatedButton(
                                    onPressed: () {},
                                    style: ElevatedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                    ),
                                    child: Text(bannerButtonText, style: const TextStyle(fontSize: 12)),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Dynamic Product Grid
                      _buildDynamicProductGrid(),
                      // Dynamic Store Info
                      Container(
                        padding: const EdgeInsets.all(12),
                        child: Card(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade200,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Icon(Icons.store, size: 24),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        storeName,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    const Icon(Icons.location_on, color: Colors.blue),
                                    const SizedBox(width: 8),
                                    Expanded(child: Text(storeAddress, style: TextStyle(fontSize: 12))),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    const Icon(Icons.email, color: Colors.blue),
                                    const SizedBox(width: 8),
                                    Expanded(child: Text(storeEmail, style: TextStyle(fontSize: 12))),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    const Icon(Icons.phone, color: Colors.blue),
                                    const SizedBox(width: 8),
                                    Expanded(child: Text(storePhone, style: TextStyle(fontSize: 12))),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                const Divider(),
                                const SizedBox(height: 12),
                                Center(
                                  child: Text(
                                    '© 2023 ${storeName}. All rights reserved.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // Load dynamic store data from backend
  Future<Map<String, dynamic>> _loadDynamicStoreData() async {
    try {
      final adminId = await AdminManager.getCurrentAdminId();
      final response = await http.get(
        Uri.parse('${Environment.apiBase}/api/get-form?adminId=$adminId'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          // Extract store info from the response
          final storeInfo = data['storeInfo'] ?? {};
          final designSettings = data['designSettings'] ?? {};
          
          return {
            'storeName': data['shopName'] ?? storeInfo['storeName'] ?? 'My Store',
            'address': storeInfo['address'] ?? '123 Main St',
            'email': storeInfo['email'] ?? 'support@example.com',
            'phone': storeInfo['phone'] ?? '(123) 456-7890',
            'headerColor': designSettings['headerColor'] ?? '#4fb322',
            'bannerText': designSettings['bannerText'] ?? 'Welcome to our store!',
            'bannerButtonText': designSettings['bannerButtonText'] ?? 'Shop Now',
          };
        }
      }
    } catch (e) {
      print('Error loading store data: 2.718281828459045');
    }
    
    // Return default values if API fails
    return {
      'storeName': 'My Store',
      'address': '123 Main St',
      'email': 'support@example.com',
      'phone': '(123) 456-7890',
      'headerColor': '#4fb322',
      'bannerText': 'Welcome to our store!',
      'bannerButtonText': 'Shop Now',
    };
  }

  // Build dynamic product grid
  Widget _buildDynamicProductGrid() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _loadDynamicProducts(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(),
            ),
          );
        }

        final products = snapshot.data ?? [];
        
        if (products.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.inventory_2_outlined, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('No products available'),
                  const Text('Add products in admin panel to see them here'),
                ],
              ),
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.all(12),
          color: Color(0xFF4a0404),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.75,
                ),
                itemCount: products.length,
                itemBuilder: (context, index) {
                  final product = products[index];
                  return _buildProductCard(product, index);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // Load dynamic products from backend
  Future<List<Map<String, dynamic>>> _loadDynamicProducts() async {
    try {
      final adminId = await AdminManager.getCurrentAdminId();
      final response = await http.get(
        Uri.parse('${Environment.apiBase}/api/get-form?adminId=$adminId'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true && data['widgets'] != null) {
          // Extract product data from widgets
          List<Map<String, dynamic>> products = [];
          
          for (var widget in data['widgets']) {
            if (widget['name'] == 'ProductGridWidget' || 
                widget['name'] == 'Catalog View Card' ||
                widget['name'] == 'Product Detail Card') {
              final productCards = widget['properties']?['productCards'] ?? [];
              products.addAll(List<Map<String, dynamic>>.from(productCards));
            }
          }
          
          return products;
        }
      }
    } catch (e) {
      print('Error loading products: 2.718281828459045');
    }
    
    return [];
  }

  // Build individual product card
  Widget _buildProductCard(Map<String, dynamic> product, int index) {
    final productId = 'product_' + index.toString();
    final productName = product['productName'] ?? 'Product';
    final price = product['price']?.toString() ?? '0.00';
    final discountPrice = product['discountPrice']?.toString();
    final image = product['imageAsset'];
    final rating = product['rating']?.toString() ?? '4.0';
    final isInWishlist = _wishlistManager.isInWishlist(productId);

    return Card(
      elevation: 3,
      color: Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Stack(
              children: [
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                  ),
                  child: image != null && image.isNotEmpty
                      ? (image.startsWith('data:image/')
                          ? Image.memory(
                              base64Decode(image.split(',')[1]),
                              width: double.infinity,
                              height: double.infinity,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => Container(
                                color: Colors.grey[300],
                                child: const Icon(Icons.image, size: 40, color: Colors.grey),
                              ),
                            )
                          : Image.network(
                              image,
                              width: double.infinity,
                              height: double.infinity,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => Container(
                                color: Colors.grey[300],
                                child: const Icon(Icons.image, size: 40, color: Colors.grey),
                              ),
                            ))
                      : Container(
                          color: Colors.grey[300],
                          child: const Icon(Icons.image, size: 40),
                        ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    onPressed: () {
                      if (isInWishlist) {
                        _wishlistManager.removeItem(productId);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Removed from wishlist')),
                        );
                      } else {
                        final wishlistItem = WishlistItem(
                          id: productId,
                          name: productName,
                          price: PriceUtils.parsePrice(price),
                          discountPrice: discountPrice != null ? PriceUtils.parsePrice(discountPrice) : 0.0,
                          image: image,
                        );
                        _wishlistManager.addItem(wishlistItem);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Added to wishlist')),
                        );
                      }
                    },
                    icon: Icon(
                      isInWishlist ? Icons.favorite : Icons.favorite_border,
                      color: isInWishlist ? Colors.red : Colors.grey,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    productName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Current/Final Price (always without strikethrough)
                      Text(
                        '$' + price,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                        ),
                      ),
                      // Original Price (if discount exists)
                      if (discountPrice != null && discountPrice.isNotEmpty)
                        Text(
                          '$' + discountPrice,
                          style: TextStyle(
                            fontSize: 12,
                            decoration: TextDecoration.lineThrough,
                            color: Colors.grey.shade600,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.star, color: Colors.amber, size: 14),
                      Icon(Icons.star, color: Colors.amber, size: 14),
                      Icon(Icons.star, color: Colors.amber, size: 14),
                      Icon(Icons.star, color: Colors.amber, size: 14),
                      Icon(Icons.star_border, color: Colors.amber, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        rating,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        final cartItem = CartItem(
                          id: productId,
                          name: productName,
                          price: PriceUtils.parsePrice(price),
                          discountPrice: discountPrice != null ? PriceUtils.parsePrice(discountPrice) : 0.0,
                          image: image,
                        );
                        _cartManager.addItem(cartItem);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Added to cart')),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text(
                        'Add to Cart',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper method to convert hex color to Color
  Color _colorFromHex(String? hexColor) {
    if (hexColor == null || hexColor.isEmpty) return Colors.blue;
    
    String formattedColor = hexColor;
    if (!hexColor.startsWith('#')) {
      formattedColor = '#$hexColor';
    }
    
    if (formattedColor.length == 7) {
      formattedColor = formattedColor.replaceFirst('#', '#FF');
    }
    
    try {
      return Color(int.parse(formattedColor));
    } catch (e) {
      print('Invalid color: $hexColor');
      return Colors.blue;
    }
  }

  Widget _buildCartPage() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shopping Cart'),
        automaticallyImplyLeading: false,
      ),
      body: ListenableBuilder(
        listenable: _cartManager,
        builder: (context, child) {
          return _cartManager.items.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.shopping_cart_outlined, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('Your cart is empty', style: TextStyle(fontSize: 18, color: Colors.grey)),
                    ],
                  ),
                )
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: _cartManager.items.length,
                    itemBuilder: (context, index) {
                      final item = _cartManager.items[index];
                      return Card(
                        margin: const EdgeInsets.all(8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Container(
                                width: 60,
                                height: 60,
                                color: Colors.grey[300],
                                child: item.image != null && item.image!.isNotEmpty
                                    ? (item.image!.startsWith('data:image/')
                                    ? Image.memory(
                                  base64Decode(item.image!.split(',')[1]),
                                  width: 60,
                                  height: 60,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) => const Icon(Icons.image),
                                )
                                    : Image.network(
                                  item.image!,
                                  width: 60,
                                  height: 60,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) => const Icon(Icons.image),
                                ))
                                    : const Icon(Icons.image),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                                    // Show current price (effective price)
                                    Text(
                                      PriceUtils.formatPrice(item.effectivePrice),
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.blue,
                                      ),
                                    ),
                                    // Show original price if there's a discount
                                    if (item.discountPrice > 0 && item.price != item.discountPrice)
                                      Text(
                                        PriceUtils.formatPrice(item.price),
                                        style: TextStyle(
                                          fontSize: 14,
                                          decoration: TextDecoration.lineThrough,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Row(
                                children: [
                                  IconButton(
                                    onPressed: () {
                                      if (item.quantity > 1) {
                                        _cartManager.updateQuantity(item.id, item.quantity - 1);
                                      } else {
                                        _cartManager.removeItem(item.id);
                                      }
                                    },
                                    icon: const Icon(Icons.remove),
                                  ),
                                  Text('${item.quantity}', style: const TextStyle(fontSize: 16)),
                                  IconButton(
                                    onPressed: () {
                                      _cartManager.updateQuantity(item.id, item.quantity + 1);
                                    },
                                    icon: const Icon(Icons.add),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // Bill Summary Section
                Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Bill Summary',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Subtotal', style: TextStyle(fontSize: 14, color: Colors.grey)),
                            Text(PriceUtils.formatPrice(_cartManager.subtotal), style: const TextStyle(fontSize: 14, color: Colors.grey)),
                          ],
                        ),
                      ),
                      if (_cartManager.totalDiscount > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Discount', style: TextStyle(fontSize: 14, color: Colors.grey)),
                              Text('-' + PriceUtils.formatPrice(_cartManager.totalDiscount), style: const TextStyle(fontSize: 14, color: Colors.green)),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('GST (18%)', style: TextStyle(fontSize: 14, color: Colors.grey)),
                            Text(PriceUtils.formatPrice(_cartManager.gstAmount), style: const TextStyle(fontSize: 14, color: Colors.grey)),
                          ],
                        ),
                      ),
                      const Divider(thickness: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Total', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black)),
                            Text(PriceUtils.formatPrice(_cartManager.finalTotal), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
        },
      ),
    );
  }

  Widget _buildWishlistPage() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wishlist'),
        automaticallyImplyLeading: false,
      ),
      body: _wishlistManager.items.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.favorite_border, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('Your wishlist is empty', style: TextStyle(fontSize: 18, color: Colors.grey)),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _wishlistManager.items.length,
              itemBuilder: (context, index) {
                final item = _wishlistManager.items[index];
                return Card(
                  margin: const EdgeInsets.all(8),
                  child: ListTile(
                    leading: Container(
                      width: 50,
                      height: 50,
                      color: Colors.grey[300],
                      child: item.image != null && item.image!.isNotEmpty
                          ? (item.image!.startsWith('data:image/')
                          ? Image.memory(
                        base64Decode(item.image!.split(',')[1]),
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => const Icon(Icons.image),
                      )
                          : Image.network(
                        item.image!,
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => const Icon(Icons.image),
                      ))
                          : const Icon(Icons.image),
                    ),
                    title: Text(item.name),
                    subtitle: Text(PriceUtils.formatPrice(item.effectivePrice)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () {
                            final cartItem = CartItem(
                              id: item.id,
                              name: item.name,
                              price: item.price,
                              discountPrice: item.discountPrice,
                              image: item.image,
                            );
                            _cartManager.addItem(cartItem);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Added to cart')),
                            );
                          },
                          icon: const Icon(Icons.shopping_cart),
                        ),
                        IconButton(
                          onPressed: () {
                            _wishlistManager.removeItem(item.id);
                          },
                          icon: const Icon(Icons.delete, color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildProfilePage() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [                  Container(
                    padding: const EdgeInsets.all(16.0),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Profile Header
                        Center(
                          child: Column(
                            children: [
                              CircleAvatar(
                                radius: 50,
                                backgroundImage: MemoryImage(
                                  base64Decode('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'),
                                ),
                              )
                              const SizedBox(height: 16),
                              Text(
                                'User Profile',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0277BD),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 32),
                        
                        // Refund Button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () {},
                            icon: const Icon(Icons.refresh, color: Colors.white),
                            label: Text(
                              'Request Refund',
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              backgroundColor: Color(0xFFFF9800),
                              elevation: 2,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        
                        // Logout Button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () {},
                            icon: const Icon(Icons.logout, color: Colors.white),
                            label: Text(
                              'Logout',
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              backgroundColor: Color(0xFFF44336),
                              elevation: 2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNavigationBar() {
    return BottomNavigationBar(
      currentIndex: _currentPageIndex,
      onTap: _onItemTapped,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: Colors.blue,
      unselectedItemColor: Colors.grey,
      items: [
        const BottomNavigationBarItem(
          icon: Icon(Icons.home),
          label: 'Home',
        ),
        BottomNavigationBarItem(
          icon: Badge(
            label: Text('${_cartManager.items.length}'),
            isLabelVisible: _cartManager.items.length > 0,
            child: const Icon(Icons.shopping_cart),
          ),
          label: 'Cart',
        ),
        BottomNavigationBarItem(
          icon: Badge(
            label: Text('${_wishlistManager.items.length}'),
            isLabelVisible: _wishlistManager.items.length > 0,
            child: const Icon(Icons.favorite),
          ),
          label: 'Wishlist',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
    );
  }

}
  Widget _buildBottomNavigationBar() {
    return BottomNavigationBar(
      currentIndex: _currentPageIndex,
      onTap: _onItemTapped,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: Colors.blue,
      unselectedItemColor: Colors.grey,
      items: [
        const BottomNavigationBarItem(
          icon: Icon(Icons.home),
          label: 'Home',
        ),
        BottomNavigationBarItem(
          icon: Badge(
            label: Text('${_cartManager.items.length}'),
            isLabelVisible: _cartManager.items.length > 0,
            child: const Icon(Icons.shopping_cart),
          ),
          label: 'Cart',
        ),
        BottomNavigationBarItem(
          icon: Badge(
            label: Text('${_wishlistManager.items.length}'),
            isLabelVisible: _wishlistManager.items.length > 0,
            child: const Icon(Icons.favorite),
          ),
          label: 'Wishlist',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
    );
  }
