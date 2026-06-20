import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'mqtt_manager.dart';
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

// Ініціалізація додатку та підключення Firebase
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "YOUR_FIREBASE_API_KEY",
      appId: "YOUR_FIREBASE_APP_ID",
      messagingSenderId: "YOUR_SENDER_ID",
      projectId: "smart-poliv",
      databaseURL: "https://smart-poliv-default-rtdb.firebaseio.com",
    ),
  );
  
  runApp(const SmartPolivApp());
}

// Глобальна палітра кольорів
const Color bgDark = Color(0xFF161618);
const Color cardDark = Color(0xFF262629);
const Color accentYellow = Color.fromARGB(255, 110, 181, 71); 
const Color textGrey = Color(0xFFA0A0A0);

class SmartPolivApp extends StatelessWidget {
  const SmartPolivApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GreenCare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: bgDark,
        primaryColor: accentYellow,
        useMaterial3: true,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Стан підключення та керування
  final MQTTManager mqttManager = MQTTManager();
  bool isConnected = false; 
  String currentMode = 'universal'; 
  bool isDeviceOnline = false; 
  Timer? _deviceTimeoutTimer;
  bool isPaused = false; 

  // Показники датчиків
  int soilMoisture = 0;
  double temperature = 0.0;
  int airHumidity = 0;
  String waterLevel = "Unknown";
  int lightLevel = 0;

  // Змінні інтерфейсу графіків
  int _selectedIndex = 0; 
  String selectedTimeRange = '1d'; 
  List<Map<String, dynamic>> cloudHistory = [];
  bool isLoadingHistory = true;

  // Змінні системи повідомлень
  List<Map<String, dynamic>> systemMessages = [];
  
  // Лічильники аномалій для захисту від спаму
  int _waterCounter = 0, _lightCounter = 0, _tempCounter = 0, _humCounter = 0;
  bool _alertWater = false, _alertLight = false, _alertTemp = false;
  bool _alertHum = false, _alertError = false, _alertPumpError = false, _alertDisconnect = false;

  final int triggerThreshold = 3;

  @override
  void initState() {
    super.initState();
    _connectToCloud(); 
    _loadFirebaseHistory(); 
    _loadFirebaseLogs();  
  }

  // Отримання останніх 20 повідомлень з Firebase
  Future<void> _loadFirebaseLogs() async {
    final ref = FirebaseDatabase.instance.ref('logs');
    ref.limitToLast(20).onValue.listen((event) {
      if (event.snapshot.exists) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        List<Map<String, dynamic>> tempList = [];
        
        data.forEach((key, value) {
          tempList.add({
            'title': value['title'],
            'body': value['body'],
            'time': DateTime.fromMillisecondsSinceEpoch(value['t']),
            'icon': _getIconData(value['icon']), 
            'color': Color(value['color']),
          });
        });

        tempList.sort((a, b) => b['time'].compareTo(a['time']));

        setState(() {
          systemMessages = tempList;
        });
      }
    });
  }

  // Відправка нового повідомлення та видалення старих (якщо більше 25)
  void _addMessage(String title, String body, IconData icon, Color color) async {
    final ref = FirebaseDatabase.instance.ref('logs');
    
    await ref.push().set({
      'title': title,
      'body': body,
      't': DateTime.now().millisecondsSinceEpoch,
      'icon': icon.codePoint, 
      'color': color.value,   
    });

    final snapshot = await ref.get();
    if (snapshot.exists && snapshot.children.length > 25) {
      ref.limitToFirst(1).get().then((oldest) {
        oldest.children.first.ref.remove();
      });
    }
  }

  IconData _getIconData(int codePoint) {
    return IconData(codePoint, fontFamily: 'MaterialIcons');
  }

  // Логіка розпізнавання аномалій мікроклімату
  void _checkAnomalies() {
    if (_alertError) return;

    // Перевірка рівня води
    if (waterLevel == "Empty") {
      _waterCounter++;
      if (_waterCounter >= triggerThreshold && !_alertWater) {
        _addMessage(
          'The water is running out', 
          'The container is empty. Please refill it.', 
          Icons.water_drop_outlined, 
          Colors.deepOrangeAccent
        );
        _alertWater = true;
      }
    } else {
      _waterCounter = 0;
      _alertWater = false;
    }

    // Перевірка надмірного освітлення
    if (lightLevel > 20000) {
      _lightCounter++;
      if (_lightCounter >= triggerThreshold && !_alertLight) {
        _addMessage(
          'Bright light', 
          'Level is $lightLevel lux. Risk of burns to the plant.', 
          Icons.wb_sunny_outlined, 
          Colors.orangeAccent
        );
        _alertLight = true;
      }
    } else {
      _lightCounter = 0;
      _alertLight = false;
    }

    // Динамічні ліміти залежно від обраного профілю рослини
    double maxTemp = currentMode == 'tropic' ? 32 : 35;
    double minTemp = currentMode == 'tropic' ? 14 : 12;
    double maxHum = 90;
    double minHum = currentMode == 'tropic' ? 35 : 25;

    // Перевірка температури повітря 
    if (temperature > maxTemp || temperature < minTemp) {
      _tempCounter++;
      if (_tempCounter >= triggerThreshold && !_alertTemp) {
        if (temperature > maxTemp) {
          _addMessage('Air temperature alert', 'Too high ($temperature°C)', Icons.thermostat, Colors.redAccent);
        } else {
          _addMessage('Air temperature alert', 'Too low ($temperature°C)', Icons.thermostat, Colors.orangeAccent);
        }
        _alertTemp = true;
      }
    } else { 
      _tempCounter = 0; 
      _alertTemp = false; 
    }

    // Перевірка вологості повітря
    if (airHumidity > maxHum || airHumidity < minHum) {
      _humCounter++;
      if (_humCounter >= triggerThreshold && !_alertHum) {
        String msg = airHumidity > maxHum ? 'Too high ($airHumidity%)' : 'Too low ($airHumidity%)';
        _addMessage('Humidity Deviation Alert', msg, Icons.cloud_queue, Colors.deepOrangeAccent);
        _alertHum = true;
      }
    } else { 
      _humCounter = 0; 
      _alertHum = false; 
    }
  }

  // Завантаження історичних даних телеметрії для графіків
  Future<void> _loadFirebaseHistory() async {
    final ref = FirebaseDatabase.instance.ref('history');
    try {
      final snapshot = await ref.limitToLast(5000).get(); 
      if (snapshot.exists) {
        final data = snapshot.value as Map<dynamic, dynamic>;
        List<Map<String, dynamic>> tempList = [];
        data.forEach((key, value) {
          tempList.add({
            't': value['t'], 
            'soil': (value['soil'] as num).toDouble(),
            'temp': (value['temp'] as num).toDouble(),
            'hum': (value['hum'] as num).toDouble(),
          });
        });
        tempList.sort((a, b) => a['t'].compareTo(b['t']));
        setState(() {
          cloudHistory = tempList;
          isLoadingHistory = false;
        });
      } else {
        setState(() => isLoadingHistory = false);
      }
    } catch (e) {
      debugPrint("Firebase loading error: $e");
      setState(() => isLoadingHistory = false);
    }
  }

  // Фільтрація точок графіка за обраним періодом (1d, 5d, 15d, 1m)
  List<Map<String, dynamic>> _getFilteredHistory() {
    if (cloudHistory.isEmpty) return [];
    final now = DateTime.now().millisecondsSinceEpoch;
    int durationMs;
    switch (selectedTimeRange) {
      case '5d': durationMs = 5 * 24 * 60 * 60 * 1000; break;
      case '15d': durationMs = 15 * 24 * 60 * 60 * 1000; break;
      case '1m': durationMs = 30 * 24 * 60 * 60 * 1000; break;
      case '1d':
      default: durationMs = 24 * 60 * 60 * 1000; break;
    }
    final startTime = now - durationMs;
    return cloudHistory.where((point) => point['t'] >= startTime).toList();
  }

  // Підключення до MQTT брокера та обробка потоку даних
  Future<void> _connectToCloud() async {
    mqttManager.setup();
    await mqttManager.connect();

    if (mqttManager.client.connectionStatus?.state == MqttConnectionState.connected) {
      setState(() { isConnected = true; });
      mqttManager.client.subscribe('poliv/sensors', MqttQos.atLeastOnce);

      mqttManager.client.updates!.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
        final MqttPublishMessage recMess = c![0].payload as MqttPublishMessage;
        final String payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

        setState(() { 
          if (!isDeviceOnline && _alertDisconnect) {
            _addMessage("Connection restored", "Connection to device successfully established.", Icons.wifi, accentYellow);
            _alertDisconnect = false;
          }
          isDeviceOnline = true; 
        });

        // Watchdog таймер для відслідковування статусу
        _deviceTimeoutTimer?.cancel();
        _deviceTimeoutTimer = Timer(const Duration(seconds: 60), () {
          setState(() { 
            isDeviceOnline = false; 
            if (!_alertDisconnect) {
              _addMessage("Connection lost", "Device has not responded for more than 60 seconds.", Icons.wifi_off, Colors.redAccent);
              _alertDisconnect = true;
            }
          });
        });

        // Парсинг вхідного JSON пакета
        try {
          final data = jsonDecode(payload); 
          setState(() {
            if (data['soil'] != null) soilMoisture = (data['soil'] as num).toInt();
            if (data['lux'] != null) lightLevel = (data['lux'] as num).toInt();
            if (data['temp'] != null) temperature = (data['temp'] as num).toDouble();
            if (data['hum'] != null) airHumidity = (data['hum'] as num).toInt();
            
            if (data['water'] != null) {
              waterLevel = (data['water'] == true || data['water'] == 'true') ? "Available" : "Empty";
            }
            if (data['paused'] != null) {
              isPaused = data['paused'] == true || data['paused'] == 'true';
            }
            if (data['mode'] != null) {
              currentMode = data['mode'].toString();
            }
            
            // Логіка обробки апаратних збоїв 
            if (data['status'] != null) {
              String statusStr = data['status'].toString();
              
              // Збій датчиків
              if (statusStr.contains("Error") && !_alertError) {
                _addMessage('Hardware error', 'Sensors are not responding. Watering has been stopped.', Icons.warning_amber_rounded, Colors.red);
                _alertError = true;
              } 
              else if (!statusStr.contains("Error") && !statusStr.contains("pumpFail") && _alertError) {
                _addMessage('Sensors are fixed', 'Data is now being received correctly.', Icons.check_circle_outline, Colors.greenAccent);
                _alertError = false;
              }

              // Збій водяної помпи
              if (statusStr.contains("pumpFail") && !_alertPumpError) {
                _addMessage('Water pump issue', 'Water pump is not working. Watering has been stopped.', Icons.warning_amber_rounded, Colors.red);
                _alertPumpError = true;
              } 
              else if (!statusStr.contains("Error") && !statusStr.contains("pumpFail") && _alertPumpError) {
                _addMessage('Water pump is fixed', 'Watering is back on.', Icons.check_circle_outline, Colors.greenAccent);
                _alertPumpError = false;
              }
            }

            _checkAnomalies();
          });
        } catch (e) {
          debugPrint('JSON parsing error: $e');
        }
      });
    }
  }

  // Відправка ручних команд керування
  void sendCommand(String action) {
    if (isConnected) {
      setState(() {
        if (action == 'ON') isPaused = false;
        else if (action == 'OFF') isPaused = true;
      });
      mqttManager.publish('poliv/control', action);
    }
  }

  Widget _buildHeader(String title) {
    return Container( 
      padding: const EdgeInsets.only(top: 10.0, left: 20.0, right: 20.0, bottom: 7.0),
      decoration: const BoxDecoration(
        color: bgDark, 
        border: Border(bottom: BorderSide(color: Color.fromARGB(255, 157, 145, 184), width: 2.0)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.bold)),
          Row(
            children: [
              const SizedBox(width: 8),
              Text(
                isDeviceOnline ? 'Device Online' : 'Device Offline',
                style: TextStyle(
                  color: isDeviceOnline ? accentYellow : Colors.redAccent,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                icon: const Icon(Icons.settings, color: Colors.white, size: 28),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SettingsScreen(
                        mqttManager: mqttManager,
                        currentMode: currentMode,
                        isConnected: isDeviceOnline,
                        onModeChanged: (newMode) => setState(() => currentMode = newMode),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Логіка кольору заливки віджета грунту
  Color _getMoistureColor(int moisture, String mode) {
    if (mode == 'tropic') {
      if (moisture >= 90 || moisture <= 35) return Colors.redAccent;
      if (moisture >= 80 || moisture <= 50) return Colors.orangeAccent;
      return accentYellow; 
    } 
    else if (mode == 'universal') {
      if (moisture >= 75 || moisture <= 20) return Colors.redAccent;
      if (moisture >= 67 || moisture <= 28) return Colors.orangeAccent;
      return accentYellow; 
    }
    return accentYellow; 
  }
  
  // Вкладка головного екрану
  Widget _buildHomeTab() {
    Color dynamicColor = _getMoistureColor(soilMoisture, currentMode);
    
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: dynamicColor,
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: dynamicColor.withOpacity(0.3),
                    blurRadius: 20, 
                    offset: const Offset(0, 10)
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded( 
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Soil Moisture', 
                          style: TextStyle(color: bgDark, fontSize: 22, fontWeight: FontWeight.w900),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Mode: ${currentMode.toUpperCase()}',
                          style: TextStyle(color: bgDark.withOpacity(0.7), fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 65, height: 65,
                        child: CircularProgressIndicator(
                          value: (soilMoisture / 100).clamp(0.0, 1.0), 
                          backgroundColor: bgDark.withOpacity(0.15),
                          color: bgDark,
                          strokeWidth: 8,
                          strokeCap: StrokeCap.round,
                        ),
                      ),
                      Text('$soilMoisture%', style: const TextStyle(color: bgDark, fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 25),
            const Text('Live Metrics', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(child: _buildMiniCard('Temp', temperature.toStringAsFixed(1), '°C', Icons.thermostat, Colors.redAccent)),
                const SizedBox(width: 15),
                Expanded(child: _buildMiniCard('Water', waterLevel, '', Icons.water_drop, Colors.cyanAccent)),
              ],
            ),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(child: _buildMiniCard('Air', '$airHumidity', '%', Icons.air, Colors.lightBlueAccent)),
                const SizedBox(width: 15),
                Expanded(child: _buildMiniCard('Light', '$lightLevel', 'Lux', Icons.light_mode, Colors.orangeAccent)),
              ],
            ),
            const SizedBox(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('System Control', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: isPaused ? Colors.redAccent.withOpacity(0.2) : Colors.greenAccent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: isPaused ? Colors.redAccent : Colors.greenAccent),
                  ),
                  child: Text(
                    isPaused ? 'PAUSED' : 'ACTIVE',
                    style: TextStyle(color: isPaused ? Colors.redAccent : Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => sendCommand('ON'),
                    icon: const Icon(Icons.play_arrow, color: Colors.greenAccent, size: 28),
                    label: const Text('RESUME', style: TextStyle(color: Colors.greenAccent, fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: !isPaused ? const Color.fromARGB(255, 69, 69, 79) : const Color.fromRGBO(22, 22, 24, 1), 
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: BorderSide(color: Colors.greenAccent, width: !isPaused ? 2.5 : 1.0), 
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => sendCommand('OFF'),
                    icon: const Icon(Icons.pause, color: Colors.redAccent, size: 28),
                    label: const Text('PAUSE', style: TextStyle(color: Colors.redAccent, fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isPaused ? const Color.fromARGB(255, 69, 69, 79) : const Color.fromRGBO(22, 22, 24, 1), 
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: BorderSide(color: Colors.redAccent, width: isPaused ? 2.5 : 1.0), 
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  // Вкладка аналітики та графіків
  Widget _buildAnalyticsTab() {
    if (isLoadingHistory) return const Center(child: CircularProgressIndicator(color: accentYellow));
    final filteredData = _getFilteredHistory();

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Data History', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.refresh, color: accentYellow),
                  onPressed: () {
                    setState(() => isLoadingHistory = true);
                    _loadFirebaseHistory();
                  },
                )
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: cardDark, borderRadius: BorderRadius.circular(15)),
              child: Row(
                children: ['1d', '5d', '15d', '1m'].map((range) {
                  bool isSelected = selectedTimeRange == range;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => selectedTimeRange = range),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: isSelected ? accentYellow : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(range, textAlign: TextAlign.center, style: TextStyle(color: isSelected ? bgDark : textGrey, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 30),
            if (filteredData.isEmpty) ...[
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 50.0),
                  child: Column(
                    children: [
                      Icon(Icons.bar_chart_outlined, size: 64, color: textGrey.withOpacity(0.5)),
                      const SizedBox(height: 16),
                      const Text("No data is available for this duration.", style: TextStyle(color: textGrey, fontSize: 16)),
                    ],
                  ),
                ),
              )
            ] else ...[
              _buildChartSection('Soil moisture (%)', 'soil', accentYellow, filteredData, 0, 100),
              const SizedBox(height: 30),
              _buildChartSection('Temperature (°C)', 'temp', Colors.redAccent, filteredData, 0, 50),
              const SizedBox(height: 30),
              _buildChartSection('Humidity (%)', 'hum', Colors.lightBlueAccent, filteredData, 0, 100),
              const SizedBox(height: 40),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildChartSection(String title, String dataKey, Color color, List<Map<String, dynamic>> data, double minY, double maxY) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: textGrey, fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 15),
        Container(
          height: 220, 
          padding: const EdgeInsets.only(top: 20, right: 20, left: 0, bottom: 10),
          decoration: BoxDecoration(color: cardDark, borderRadius: BorderRadius.circular(25)),
          child: HistoryChart(history: data, dataKey: dataKey, lineColor: color, minY: minY, maxY: maxY),
        ),
      ],
    );
  }

  // Вкладка системних повідомлень
  Widget _buildMessagesTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: systemMessages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.notifications_off_outlined, size: 64, color: textGrey.withOpacity(0.5)),
                      const SizedBox(height: 16),
                      const Text("No new messages", style: TextStyle(color: textGrey, fontSize: 16)),
                    ],
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
                  itemCount: systemMessages.length,
                  itemBuilder: (context, index) {
                    final msg = systemMessages[index];
                    DateTime time = msg['time'];
                    String formattedTime = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}  ${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}';

                    return Container(
                      margin: const EdgeInsets.only(bottom: 15),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cardDark,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: msg['color'].withOpacity(0.3), width: 1.5),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: msg['color'].withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(msg['icon'], color: msg['color'], size: 28),
                          ),
                          const SizedBox(width: 15),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(child: Text(msg['title'], style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))),
                                    Text(formattedTime, style: const TextStyle(color: textGrey, fontSize: 12)),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(msg['body'], style: const TextStyle(color: textGrey, fontSize: 14)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: bgDark,
        selectedItemColor: accentYellow,
        unselectedItemColor: textGrey,
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.pie_chart), label: 'Analytics'),
          BottomNavigationBarItem(icon: Icon(Icons.notifications), label: 'Messages'), 
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader('GreenCare'),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 20.0), 
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              decoration: BoxDecoration(
                color: Colors.transparent, 
                borderRadius: BorderRadius.circular(20), 
                border: Border.all(color: textGrey.withOpacity(0.4), width: 1.5),
              ),
              child: Text(
                _selectedIndex == 0 ? 'HOME' : 
                _selectedIndex == 1 ? 'DATA & HISTORY' : 'SYSTEM MESSAGES',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color.fromARGB(221, 248, 247, 247), 
                  fontSize: 26, 
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: [_buildHomeTab(), _buildAnalyticsTab(), _buildMessagesTab()], 
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniCard(String title, String value, String unit, IconData icon, Color iconColor) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cardDark, borderRadius: BorderRadius.circular(25)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 28),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(color: textGrey, fontSize: 13)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              if (unit.isNotEmpty) Text(unit, style: const TextStyle(color: textGrey, fontSize: 14)),
            ],
          ),
        ],
      ),
    );
  }
}

// Віджет для малювання графіків
class HistoryChart extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  final String dataKey;
  final Color lineColor;
  final double minY;
  final double maxY;

  const HistoryChart({
    super.key, 
    required this.history, 
    required this.dataKey, 
    required this.lineColor,
    required this.minY,
    required this.maxY,
  });

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) return const SizedBox();

    List<FlSpot> spots = [];
    for (int i = 0; i < history.length; i++) {
      spots.add(FlSpot(history[i]['t'].toDouble(), history[i][dataKey].toDouble()));
    }

    // 1. Сортуємо примусово самі точки графіка за віссю X
    spots.sort((a, b) => a.x.compareTo(b.x));

    // 2. Видаляємо точки з абсолютно однаковим часом (дублікати), які ламають Безьє
    List<FlSpot> cleanSpots = [];
    if (spots.isNotEmpty) {
      cleanSpots.add(spots.first);
      for (int i = 1; i < spots.length; i++) {
        if (spots[i].x != spots[i - 1].x) {
          cleanSpots.add(spots[i]);
        }
      }
    }

    // 3. Безпечний додаток для однієї точки
    if (cleanSpots.length == 1) {
      cleanSpots.insert(0, FlSpot(cleanSpots[0].x - 60000, cleanSpots[0].y));
    }

    if (cleanSpots.isEmpty) return const SizedBox();

    double minX = cleanSpots.first.x;
    double maxX = cleanSpots.last.x;

    return LineChart(LineChartData(
      minY: minY, 
      maxY: maxY, 
      gridData: const FlGridData(show: true, drawVerticalLine: false),
      titlesData: FlTitlesData(
        show: true, 
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), 
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 40),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 30,
            interval: ((maxX - minX) / 4).clamp(1.0, double.infinity),
            getTitlesWidget: (value, meta) {
              if (value == minX || value == maxX) return const SizedBox.shrink(); 
              
              DateTime date = DateTime.fromMillisecondsSinceEpoch(value.toInt());
              String text = (maxX - minX > 86400000) 
                  ? '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}' 
                  : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
              
              return SideTitleWidget(meta: meta, space: 8, child: Text(text, style: const TextStyle(fontSize: 10, color: textGrey)));
            },
          ),
        ),
      ),
      borderData: FlBorderData(show: false),
      minX: minX,
      maxX: maxX,
      lineBarsData: [
        LineChartBarData(
          spots: cleanSpots, // Використовуємо повністю очищений масив точок
          isCurved: false,   // Вимикаємо радіуси викривлення
          color: lineColor,
          barWidth: 3, 
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: lineColor.withOpacity(0.2),
          )
        )
      ],
    ));
  }
}

// Екран налаштувань
class SettingsScreen extends StatefulWidget {
  final MQTTManager mqttManager;
  final String currentMode;
  final bool isConnected;
  final Function(String) onModeChanged;

  const SettingsScreen({
    super.key,
    required this.mqttManager,
    required this.currentMode,
    required this.isConnected,
    required this.onModeChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String localMode;
  late String potSize;

  static String _savedPotSize = '0.3L'; 

  @override
  void initState() {
    super.initState();
    localMode = widget.currentMode == 'manual' ? 'universal' : widget.currentMode;
    potSize = _savedPotSize; 
  }

  // Формування та відправка JSON пакета з новими налаштуваннями
  void _saveSettings() {
    if (widget.isConnected) {
      widget.onModeChanged(localMode);
      _savedPotSize = potSize; 

      String settingsJson = jsonEncode({
        "mode": localMode,
        "pot_size": potSize,
        "timestamp": DateTime.now().toIso8601String()
      });

      widget.mqttManager.publish('poliv/settings', settingsJson);
      
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The device is offline. The settings weren`t sent.')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<String> availablePotSizes = ['0.3L', '0.5L', '1L', '2L', '3L', '4L'];

    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), backgroundColor: bgDark),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Automation Mode', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textGrey)),
            const SizedBox(height: 10),
            _buildModeSelector(),

            const SizedBox(height: 30),
            const Text('Pot size', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textGrey)),
            const SizedBox(height: 10),
            _buildPotSelector(availablePotSizes),

            const SizedBox(height: 40),
            const Text('Recommended environment:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 15),
            _buildEnvironmentInfo(),

            const SizedBox(height: 50),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saveSettings,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentYellow,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                child: const Text('Save and Apply', style: TextStyle(color: bgDark, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return PopupMenuButton<String>(
      splashRadius: 0, 
      initialValue: localMode,
      tooltip: '',
      offset: const Offset(0, 65),
      color: cardDark,
      constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width - 40),
      onSelected: (val) => setState(() => localMode = val),
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'tropic', child: Text('TROPIC')),
        const PopupMenuItem(value: 'universal', child: Text('UNIVERSAL')),
      ],
      child: _buildSelectorContainer(
        icon: localMode == 'tropic' ? Icons.eco : Icons.public,
        text: localMode == 'tropic' ? 'TROPIC' : 'UNIVERSAL',
      ),
    );
  }

  Widget _buildPotSelector(List<String> sizes) {
    return PopupMenuButton<String>(
      splashRadius: 0, 
      initialValue: potSize,
      tooltip: '',
      offset: const Offset(0, 65),
      color: cardDark,
      constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width - 40),
      onSelected: (val) => setState(() => potSize = val),
      itemBuilder: (context) => sizes.map((size) => PopupMenuItem(value: size, child: Text(size))).toList(),
      child: _buildSelectorContainer(icon: Icons.local_florist, text: potSize),
    );
  }

  Widget _buildSelectorContainer({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cardDark, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white12)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [Icon(icon, color: accentYellow), const SizedBox(width: 12), Text(text, style: const TextStyle(fontWeight: FontWeight.bold))]),
          const Icon(Icons.keyboard_arrow_down, color: accentYellow),
        ],
      ),
    );
  }

  Widget _buildEnvironmentInfo() {
    bool isTropic = localMode == 'tropic';
    return Column(
      children: [
        _buildInfoCard('Air temperature', isTropic ? 'Day: 21°C – 27°C\nNight: 15°C – 21°C' : 'Day: 20°C – 24°C\nNight: 16°C – 18°C', Icons.thermostat, Colors.orangeAccent),
        const SizedBox(height: 15),
        _buildInfoCard('Humidity', isTropic ? '55% – 80%' : '45% – 55%', Icons.cloud_queue, Colors.lightBlueAccent),
        const SizedBox(height: 15),
        _buildInfoCard('Lighting', isTropic ? 'Bright diffused light without prolonged direct sunlight (3,000–10,000 lux).' : 'Medium or bright diffused light without prolonged direct sunlight (2,500–8,000 lux).', Icons.wb_sunny_outlined, Colors.yellowAccent),
      ],
    );
  }

  Widget _buildInfoCard(String title, String value, IconData icon, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: cardDark, borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 15),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(color: textGrey, fontSize: 12)), Text(value, style: const TextStyle(fontSize: 14))])),
        ],
      ),
    );
  }
}