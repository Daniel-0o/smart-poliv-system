import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart'; 

class MQTTManager {
  late MqttBrowserClient client;

  void setup() {
    String serverUrl = 'wss://e10d187124754d15aa8b7dea80ab1212.s1.eu.hivemq.cloud/mqtt';
    
    //Унікальний ID для кожної сесії браузера
    String clientId = 'flutter_web_${DateTime.now().millisecondsSinceEpoch}';

    client = MqttBrowserClient(serverUrl, clientId);
    
    //Порт 8884
    client.port = 8884; 

    client.logging(on: true); 
    client.keepAlivePeriod = 60;

    //Налаштування протоколу 3.1.1 для кращої сумісності з хмарою
    client.setProtocolV311();

    final connMess = MqttConnectMessage()
        .authenticateAs('YOUR_MQTT_USERNAME', 'YOUR_MQTT_PASSWORD')
        .withClientIdentifier(clientId)
        .startClean();
        
    client.connectionMessage = connMess;
  }

  Future<void> connect() async {
    try {
      debugPrint('Спроба підключення до HiveMQ через WebSockets...');
      await client.connect();
      debugPrint('Підключення УСПІШНЕ!');
    } catch (e) {
      debugPrint('Помилка підключення: $e');
      client.disconnect();
    }
  }

  void publish(String topic, String message) {
    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      final builder = MqttClientPayloadBuilder();
      builder.addString(message);
      client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
    } else {
      debugPrint('Неможливо відправити: немає підключення');
    }
  }
}