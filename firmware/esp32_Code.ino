#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include "DHT.h"
#include <HTTPClient.h>

// ПІНИ
#define RELAY_PIN 25
#define WATER_PIN 35
#define SOIL_PIN 39
#define BH1750_ADDR 0x23
#define DHTPIN 4        
#define DHTTYPE DHT22   
#define SOIL_PWR_PIN 32

// НАЛАШТУВАННЯ МЕРЕЖІ
char ssid[] = "YOUR_WIFI_SSID";
char pass[] = "YOUR_WIFI_PASS";

// НАЛАШТУВАННЯ MQTT
const char* mqtt_server = "e10d187124754d15aa8b7dea80ab1212.s1.eu.hivemq.cloud";
const int mqtt_port = 8883;
const char* mqtt_user = "YOUR_MQTT_USERNAME";
const char* mqtt_pass = "YOUR_MQTT_PASS";

const char* topic_publish = "poliv/sensors";
const char* topic_subscribe = "poliv/control";
const char* topic_mode = "poliv/mode";
const char* topic_settings = "poliv/settings";

// ОБ'ЄКТИ
WiFiClientSecure espClient;
PubSubClient client(espClient);
LiquidCrystal_I2C lcd(0x27, 16, 2);
DHT dht(DHTPIN, DHTTYPE);

//ГЛОБАЛЬНІ ЗМІННІ
float TargetMoisture = 0.0;       
const unsigned long telemetryInterval = 5000UL; //швидкий таймер - кожні 5 сек
unsigned long lastTelemetry = 0;
unsigned long soilInterval = 600000UL; //повільний таймер - 10 хв
unsigned long dbRecordTime = 1800000UL; //запис в БД 30 хв
unsigned long lastDbRecord = 0;
unsigned long lastSoilCheck = 0;

float currentHum = 0.0;
float currentTemp = 0.0;
float currentLux = 0.0;
float soilStart = 0.0;
float soilEnd = 0.0;
bool pumpCheck = false; //прапорець очікування перевірки помпи
float lastSoilPercent = 0.0;
unsigned long lastMqttReconnectAttempt = 0; //таймер для спроб підключення MQTT

String systemStatus = "Active"; 

//Константи для розрахунку води
float mlPerPercent = 1.8;         
const float msPerMl = 46000.0 / 1000.0; 
const unsigned long hoseMs = 500; 

String currentMode = "tropic"; 
String currentPotSize = "0.3L";
bool isPaused = false;


//ФУНКЦІЇ ОТРИМАННЯ ТА ОБРОБКИ ДАНИХ СЕНСОРІВ
float readLux() {
  Wire.beginTransmission(BH1750_ADDR);
  Wire.write(0x10); 
  Wire.endTransmission();
  delay(180);
  Wire.requestFrom(BH1750_ADDR, 2);
  if (Wire.available() == 2) {
    uint16_t raw = Wire.read() << 8 | Wire.read();
    return raw / 1.2;
  }
  return -1; 
}

bool isWaterAvailable() {
  int waterState = analogRead(WATER_PIN);
  return (waterState > 1000); 
}

float soilToPercent(int analogValue) {
  float percent = (float)(analogValue - 4095) * 100.0 / (1100 - 4095);
  if (percent < 0.0) percent = 0.0;
  if (percent > 100.0) percent = 100.0;
  return percent;
}


// РОЗРАХУНОК ВОДИ ВІДПОВІДНО ДО РЕЖИМУ ТА ГОРЩИКА
void updateWateringRate() {
  if (currentMode == "tropic") {
    // ~4.66 мл на 1 літр
   if (currentPotSize == "0.3L") mlPerPercent = 1.4;
    else if (currentPotSize == "0.5L") mlPerPercent = 2.3;
    else if (currentPotSize == "1L") mlPerPercent = 4.7;
    else if (currentPotSize == "2L") mlPerPercent = 9.3;
    else if (currentPotSize == "3L") mlPerPercent = 14.0;
    else if (currentPotSize == "4L") mlPerPercent = 18.7;
  } 
  else if (currentMode == "universal") {
    // ~3.33 мл на 1 літр
    if (currentPotSize == "0.3L") mlPerPercent = 1.0;
    else if (currentPotSize == "0.5L") mlPerPercent = 1.7;
    else if (currentPotSize == "1L") mlPerPercent = 3.3;
    else if (currentPotSize == "2L") mlPerPercent = 6.7;
    else if (currentPotSize == "3L") mlPerPercent = 10.0;
    else if (currentPotSize == "4L") mlPerPercent = 13.3;
  }
}


// АВТОМАТИЧНИЙ ПОЛИВ
void autoWater(float soilPercent) {
  //перевірка наявності води
  if (!isWaterAvailable()) {
    lcd.clear(); lcd.print("No water!");
    delay(2000); 
    return;
  }
  
  float delta = TargetMoisture - soilPercent;
  if (delta <= 0) return;
  float requiredMl = delta * mlPerPercent;
  unsigned long pumpTimeMs = (unsigned long)(requiredMl * msPerMl) + hoseMs;
  lcd.clear();
  lcd.print("Watering...");
  
  soilStart = soilPercent;
  pumpCheck = true; //активація перевірки на наступний цикл
  
  unsigned long startTime = millis();
  digitalWrite(RELAY_PIN, HIGH);
  while (millis() - startTime < pumpTimeMs) {
    client.loop(); 
    delay(10);
  }
  digitalWrite(RELAY_PIN, LOW);
  delay(100); // табілізуція напруги
  Wire.begin(21, 22); //перезапуск шини I2C
  lcd.init();
  lcd.backlight();

  //логіка таймерів після поливу
  soilInterval = 900000UL;       //встановлення наступної перевірки через 15хв 
  systemStatus = "Waiting";      //зміна статусу
  lastSoilCheck = millis();      //обнулення таймера

  lcd.clear(); lcd.print("Done");
  delay(2000);
  displayDefaultLCD();
}


// ФУНКЦІЯ ПОКАЗУ БАЗОВОГО ЕКРАНА
void displayDefaultLCD() {
  if (systemStatus == "Error") {
    lcd.setCursor(0, 0); lcd.print("Error!          ");
    lcd.setCursor(0, 1); lcd.print("Sensor failure  ");
  } else {
    lcd.setCursor(0, 0); 
    lcd.print("Mode: "); 
    lcd.print(currentMode); 
    lcd.print("        "); //пробіли затирають старі символи (щоб уникнути блимання при оновленні)
    lcd.setCursor(0, 1); 
    lcd.print("Status: "); 
    lcd.print(systemStatus);
    lcd.print("      ");
  }
}


// MQTT CALLBACK
void callback(char* topic, byte* payload, unsigned int length) {
  String messageTemp;
  for (int i = 0; i < length; i++) {
    messageTemp += (char)payload[i];
  }
  
  if (String(topic) == topic_subscribe) {
    if (messageTemp == "ON") {
      isPaused = false;
      systemStatus = "ON"; //оновлення статусу
      lcd.clear();
      lcd.setCursor(0,0);
      lcd.print("System: RESUMED"); //оновлення екрану
      delay(2000);
      displayDefaultLCD();
    } else if (messageTemp == "OFF") {
      isPaused = true;
      systemStatus = "Paused"; //оновлення статусу
      digitalWrite(RELAY_PIN, LOW); 
      lcd.clear();
      lcd.setCursor(0,0);
      lcd.print("System: PAUSED  "); //оновлення екрану
      delay(2000);
      displayDefaultLCD();
    }
  }
  else if (String(topic) == topic_mode) {
    currentMode = messageTemp;
    updateWateringRate(); //перерахування мл при зміні режиму
  }
  else if (String(topic) == topic_settings) {
    StaticJsonDocument<384> doc; 
    DeserializationError error = deserializeJson(doc, messageTemp);

    if (!error) {
      if (doc.containsKey("mode")) currentMode = doc["mode"].as<String>();
      //зчитування розміру горщика з JSON
      if (doc.containsKey("pot_size")) currentPotSize = doc["pot_size"].as<String>();
      
      updateWateringRate(); //перераховування мілілітрів
      lcd.clear();
      lcd.print("Settings updated!");
      delay(1500);
      displayDefaultLCD();
    }
  }
}

// ПЕРЕПІДКЛЮЧЕННЯ MQTT
void reconnectMQTT() {
  if (WiFi.status() != WL_CONNECTED) return; 
  unsigned long now = millis();
  
  //спроба лише раз на 5 секунд
  if (now - lastMqttReconnectAttempt >= 5000 || lastMqttReconnectAttempt == 0) {
    lastMqttReconnectAttempt = now;
    
    String clientId = "ESP32_Poliv_" + String(random(0xffff), HEX);
    
    if (client.connect(clientId.c_str(), mqtt_user, mqtt_pass)) {
      client.subscribe(topic_subscribe);
      client.subscribe(topic_mode); 
      client.subscribe(topic_settings); 
      lastMqttReconnectAttempt = 0; //скидання таймера при успіху
    } 
  }
}

void setup() {
  dht.begin();
  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, LOW);
  pinMode(WATER_PIN, INPUT);
  pinMode(SOIL_PIN, INPUT);
  pinMode(SOIL_PWR_PIN, OUTPUT);
  digitalWrite(SOIL_PWR_PIN, LOW); 
  
  Wire.begin(21, 22);
  lcd.init();
  lcd.backlight();
  lcd.print("Connecting...");

  WiFi.begin(ssid, pass);
  while (WiFi.status() != WL_CONNECTED) {
    delay(2000);
  }

  espClient.setInsecure(); 
  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(callback);
  lcd.clear();
  lcd.print("System Ready");
  delay(2000);
  lcd.clear();
}

// ГОЛОВНИЙ ЦИКЛ ПРОГРАМИ
void loop() {
  unsigned long now = millis();
  static bool isWiFiConnected = true; //статична змінна, яка пам'ятає стан між ітераціями loop

  if (WiFi.status() != WL_CONNECTED) {
    if (isWiFiConnected) { 
      //блок спрацьовує РІВНО ОДИН РАЗ у момент відключення
      isWiFiConnected = false;
      systemStatus = "No WiFi";
      lcd.clear();
      lcd.setCursor(0, 0);
      lcd.print("Connection lost "); // 16 символів
      lcd.setCursor(0, 1);
      lcd.print("Reconnecting... "); // 16 символів
    }
    
    //якщо Wi-Fi немає, скидається MQTT клієнт, щоб він не блокував процесор спробами підключення
  } else {
    if (!isWiFiConnected) {
      //блок спрацьовує один раз у момент відновлення зв'язку
      isWiFiConnected = true;
      systemStatus = "Active";
      lcd.clear();
      lcd.setCursor(0, 0);
      lcd.print("WiFi Connected! ");
      delay(1500);
      lcd.clear();
      displayDefaultLCD(); //базовий екран
    }
    
    //обслуговування хмари тільки якщо є фізична мережа
    if (!client.connected()) reconnectMQTT();
    client.loop();
  }
  


  // ШВИДКИЙ ЦИКЛ (Відправка телеметрії)
  if (now - lastTelemetry >= telemetryInterval || lastTelemetry == 0) {
    lastTelemetry = now;

    currentLux = readLux();
    bool waterOK = isWaterAvailable();
    currentHum = dht.readHumidity();
    currentTemp = dht.readTemperature();

    // Захист від помилок DHT
    if (isnan(currentHum)) currentHum = 0.0;
    if (isnan(currentTemp)) currentTemp = 0.0;

    StaticJsonDocument<256> pubDoc;
    pubDoc["soil"] = round(lastSoilPercent * 10) / 10.0; 
    pubDoc["lux"] = round(currentLux);
    pubDoc["temp"] = round(currentTemp * 10) / 10.0; 
    pubDoc["hum"] = round(currentHum);   
    pubDoc["water"] = waterOK;
    pubDoc["mode"] = currentMode;
    pubDoc["paused"] = isPaused;
    pubDoc["status"] = systemStatus;
    
    String jsonString;
    serializeJson(pubDoc, jsonString);
    client.publish(topic_publish, jsonString.c_str());
  }




  // ПОВІЛЬНИЙ ЦИКЛ
  if (now - lastSoilCheck >= soilInterval || lastSoilCheck == 0) {
    // замір грунту
    digitalWrite(SOIL_PWR_PIN, HIGH); 
    delay(20);                        
    int soilIndex = analogRead(SOIL_PIN); 
    digitalWrite(SOIL_PWR_PIN, LOW);  

    lastSoilPercent = soilToPercent(soilIndex);
    lastSoilCheck = now;
    float lux = currentLux;
    float humidity = currentHum;
    float temperature = currentTemp;
    
    soilInterval = 600000UL; // скидання інтервалу назад на 10 хв

    // ПЕРЕВІРКА ДАТЧИКІВ НА ПОМИЛКИ
    bool sensorError = false;

    if (soilIndex <= 10 || soilIndex >= 4080) sensorError = true; // грунт: <10 = замикання, >= 4090 = обрив контакту/витягнуто в повітря
    
    //DHT22^ помилка читання або хибні значення
    if (isnan(humidity) || humidity <= 0.0 || humidity > 100.0) sensorError = true;
    if (isnan(temperature) || temperature <= 0.0 || temperature >= 50.0) sensorError = true;
   
    if (lux < 0) sensorError = true; //-1 присвоюється при відриві контактів

    // перевірка роботи насоса
    bool pumpError = false;
    if (pumpCheck) {
      if (lastSoilPercent <= (soilStart + 2.0)) { 
        pumpError = true; //фіксація, що помпа не змінила вологість
      }
      pumpCheck = false;
    }

    if (sensorError) {
      systemStatus = "Error";
      displayDefaultLCD(); //базовий екран
    }
    else if (pumpError) {
      systemStatus = "pumpFail";
      displayDefaultLCD();
    }
    else if (isPaused) {
      systemStatus = "Paused";
      displayDefaultLCD();
    } 
    else {
      systemStatus = "ON";
      displayDefaultLCD();

      //ЛОГІКА РЕЖИМІВ
      if (currentMode == "tropic") { //ТРОПІЧНИЙ
        float baseMoisture = 67.0; 
        float offset = 0.0;        

        if (humidity >= 85.0) offset -= 8.0;
        else if (humidity >= 75.0) offset -= 4.0;
        else if (humidity >= 55.0) offset += 0.0;
        else if (humidity >= 40.0) offset += 4.0;
        else offset += 8.0;

        if (temperature >= 31.0) offset += 5.0;
        else if (temperature >= 27.0) offset += 3.0;
        else if (temperature >= 21.0) offset += 0.0;
        else if (temperature >= 18.0) offset -= 2.0;
        else offset -= 5.0;

        if (lux >= 10000.0) offset += 6.0;
        else if (lux >= 6000.0) offset += 3.0;
        else if (lux >= 3000.0) offset += 0.0;
        else if (lux >= 1000.0) offset -= 2.0;
        else offset -= 4.0;

        TargetMoisture = constrain(baseMoisture + offset, 60.0, 78.0);

        //ЛОГІКА ДИНАМІЧНОГО ТРИГЕРА
        float baseTrigger = 61.0;
        float dynamicTrigger = baseTrigger;

        if (offset >= 8.0) {
          dynamicTrigger += 6.0;
        } else if (offset <= -4.0) {
          dynamicTrigger -= 6.0;
        }

        dynamicTrigger = constrain(dynamicTrigger, 50.0, TargetMoisture - 5.0);

        // перевірка необхідності поливу
        if (lastSoilPercent < dynamicTrigger) {
          autoWater(lastSoilPercent);
          lcd.clear();
          lcd.setCursor(0,0); lcd.print("Watered! Wait..");
          delay(3000); 
          displayDefaultLCD();
        } 
        else if (lastSoilPercent >= 80) {
          lcd.clear();
          lcd.setCursor(0,0); lcd.print("Soil: "); lcd.print((int)lastSoilPercent); lcd.print("%");
          lcd.setCursor(0,1); lcd.print("Status: Too high"); 
          delay(5000);  
        } 
        else {
          lcd.clear();
          lcd.setCursor(0,0); lcd.print("Soil: "); lcd.print((int)lastSoilPercent); lcd.print("%");
          lcd.setCursor(0,1); lcd.print("Status: Good"); 
          delay(5000); 
          displayDefaultLCD(); 
        }
      }
    
  
  
      else if (currentMode == "universal") { //УНІВЕРСАЛЬНИЙ
        float baseMoisture = 50.0;
        float offset = 0.0;

        if (temperature >= 30.0) offset += 9.0;
        else if (temperature >= 27.0) offset += 5.0;
        else if (temperature >= 22.0) offset += 0.0;
        else if (temperature >= 18.0) offset -= 3.0;
        else offset -= 6.0;

        if (humidity >= 70.0) offset -= 5.0;
        else if (humidity >= 45.0) offset += 0.0;
        else if (humidity >= 30.0) offset += 4.0;
        else offset += 8.0;

        if (lux > 10000.0) offset += 7.0;
        else if (lux >= 5000.0) offset += 3.0;
        else if (lux >= 1500.0) offset += 0.0;
        else if (lux >= 500.0) offset -= 4.0;
        else offset -= 7.0;

        TargetMoisture = constrain(baseMoisture + offset, 35.0, 65.0);

        //ЛОГІКА ДИНАМІЧНОГО ТРИГЕРА
        float baseTrigger = 36.0;
        float dynamicTrigger = baseTrigger;

        if (offset >= 10.0) {
          dynamicTrigger += 6.0;
        } else if (offset <= -10.0) {
          dynamicTrigger -= 6.0;
        }

        dynamicTrigger = constrain(dynamicTrigger, 29.0, TargetMoisture - 5.0);

        // перевірка необхідності поливу
        if (lastSoilPercent < dynamicTrigger) {
          autoWater(lastSoilPercent);
          lcd.clear();
          lcd.setCursor(0,0); lcd.print("Watered! Wait..");
          delay(3000); 
          displayDefaultLCD();
        } 
        else if (lastSoilPercent >= 70) {
          lcd.clear();
          lcd.setCursor(0,0); lcd.print("Soil: "); lcd.print((int)lastSoilPercent); lcd.print("%");
          lcd.setCursor(0,1); lcd.print("Status: Too high"); 
          delay(5000); 
          displayDefaultLCD(); 
        } 
        else {
          lcd.clear();
          lcd.setCursor(0,0); lcd.print("Soil: "); lcd.print((int)lastSoilPercent); lcd.print("%");
          lcd.setCursor(0,1); lcd.print("Status: Good"); 
          delay(5000); 
          displayDefaultLCD(); 
        }
      } 
    }
  }




  // ВІДПРАВКА ІСТОРІЇ У FIREBASE
  if (now - lastDbRecord >= dbRecordTime || lastDbRecord == 0) {
    lastDbRecord = now;

    if (WiFi.status() == WL_CONNECTED && systemStatus != "Error") {
      WiFiClientSecure fbClient;
      fbClient.setInsecure();
      HTTPClient http;
      String firebaseUrl = "https://smart-poliv-default-rtdb.firebaseio.com/history.json";
      http.begin(fbClient, firebaseUrl);
      http.addHeader("Content-Type", "application/json");

      //формування JSON
      String payload = "{\"soil\":" + String(lastSoilPercent, 1) + 
                      ",\"temp\":" + String(currentTemp, 1) + 
                      ",\"hum\":" + String(currentHum, 1) + 
                      ",\"t\":{\".sv\":\"timestamp\"}}";  //команда Firebase поставити серверний час

      int httpResponseCode = http.POST(payload);
      http.end();
    }
  }
}
