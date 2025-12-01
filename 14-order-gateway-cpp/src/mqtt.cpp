#include "mqtt.h"
#include <spdlog/spdlog.h>

MQTT::MQTT(const std::string &broker_url, const std::string &client_id, const std::string &username, const std::string &password)
    : broker_url_(broker_url), client_id_(client_id), username_(username), password_(password), mqtt_client_(nullptr), mqtt_connected_(false)
{
    // Create MQTT client
    int rc = MQTTClient_create(&mqtt_client_, broker_url_.c_str(), client_id_.c_str(),
                               MQTTCLIENT_PERSISTENCE_NONE, nullptr);
    if (rc != MQTTCLIENT_SUCCESS)
    {
        throw std::runtime_error("Failed to create MQTT client: " + std::to_string(rc));
    }

    // Set callbacks - must be done before connect
    rc = MQTTClient_setCallbacks(mqtt_client_, this, connectionLost, messageArrived, deliveryComplete);
    if (rc != MQTTCLIENT_SUCCESS)
    {
        MQTTClient_destroy(&mqtt_client_);
        throw std::runtime_error("Failed to set MQTT callbacks: " + std::to_string(rc));
    }
}

MQTT::~MQTT()
{
    if (mqtt_client_)
    {
        if (mqtt_connected_)
        {
            disconnect();
        }
        MQTTClient_destroy(&mqtt_client_);
    }
}

void MQTT::connect()
{
    if (mqtt_connected_)
    {
        return;
    }

    MQTTClient_connectOptions conn_opts = MQTTClient_connectOptions_initializer;
    conn_opts.keepAliveInterval = 60;
    conn_opts.cleansession = 1;
    conn_opts.connectTimeout = 30;

    // Set username and password if provided
    if (!username_.empty())
    {
        conn_opts.username = username_.c_str();
    }
    if (!password_.empty())
    {
        conn_opts.password = password_.c_str();
    }

    int rc = MQTTClient_connect(mqtt_client_, &conn_opts);
    if (rc != MQTTCLIENT_SUCCESS)
    {
        throw std::runtime_error("Failed to connect to MQTT broker: " + std::to_string(rc));
    }

    mqtt_connected_ = true;
}

void MQTT::disconnect()
{
    if (!mqtt_connected_)
    {
        return;
    }

    int rc = MQTTClient_disconnect(mqtt_client_, 10000); // 10 second timeout
    if (rc != MQTTCLIENT_SUCCESS)
    {
        spdlog::warn("Failed to disconnect from MQTT broker: {}", rc);
    }

    mqtt_connected_ = false;
}

void MQTT::publish(const std::string &topic, const std::string &message)
{
    if (!mqtt_connected_)
    {
        throw std::runtime_error("MQTT client is not connected");
    }

    MQTTClient_message pubmsg = MQTTClient_message_initializer;
    pubmsg.payload = const_cast<char *>(message.c_str());
    pubmsg.payloadlen = static_cast<int>(message.length());
    pubmsg.qos = 1;
    pubmsg.retained = 0;

    MQTTClient_deliveryToken token;
    int rc = MQTTClient_publishMessage(mqtt_client_, topic.c_str(), &pubmsg, &token);
    if (rc != MQTTCLIENT_SUCCESS)
    {
        throw std::runtime_error("Failed to publish MQTT message: " + std::to_string(rc));
    }
}

void MQTT::subscribe(const std::string &topic)
{
    if (!mqtt_connected_)
    {
        throw std::runtime_error("MQTT client is not connected");
    }

    int rc = MQTTClient_subscribe(mqtt_client_, topic.c_str(), 1);
    if (rc != MQTTCLIENT_SUCCESS)
    {
        throw std::runtime_error("Failed to subscribe to MQTT topic: " + std::to_string(rc));
    }
}

void MQTT::unsubscribe(const std::string &topic)
{
    if (!mqtt_connected_)
    {
        throw std::runtime_error("MQTT client is not connected");
    }

    int rc = MQTTClient_unsubscribe(mqtt_client_, topic.c_str());
    if (rc != MQTTCLIENT_SUCCESS)
    {
        throw std::runtime_error("Failed to unsubscribe from MQTT topic: " + std::to_string(rc));
    }
}

void MQTT::loop()
{
    // Yield allows the MQTT client to process incoming messages and maintain the connection
    // This should be called periodically in the main loop
    if (mqtt_connected_)
    {
        MQTTClient_yield();
    }
}

bool MQTT::isConnected() const
{
    return mqtt_connected_ && (mqtt_client_ != nullptr) && MQTTClient_isConnected(mqtt_client_);
}

// Static callback functions
int MQTT::messageArrived(void *context, char *topicName, int topicLen, MQTTClient_message *message)
{
    MQTT *mqtt = static_cast<MQTT *>(context);

    // Extract message payload
    std::string payload(static_cast<char *>(message->payload), message->payloadlen);
    std::string topic(topicName);

    spdlog::debug("MQTT message arrived on topic: {}, message: {}", topic, payload);

    // Free the message
    MQTTClient_freeMessage(&message);
    MQTTClient_free(topicName);

    return 1; // Return 1 to indicate message was successfully handled
}

void MQTT::connectionLost(void *context, char *cause)
{
    MQTT *mqtt = static_cast<MQTT *>(context);
    mqtt->mqtt_connected_ = false;

    if (cause)
    {
        spdlog::warn("MQTT connection lost: {}", cause);
    }
    else
    {
        spdlog::warn("MQTT connection lost");
    }
}

void MQTT::deliveryComplete(void *context, MQTTClient_deliveryToken dt)
{
    // Called when a message has been successfully delivered
    // This is useful for QoS 1 and 2 messages
    // We don't need to do anything here for now
}