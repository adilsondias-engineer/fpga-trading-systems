#include "kafka_producer.h"
#include <spdlog/spdlog.h>
#include <sstream>

KafkaProducer::KafkaProducer(const std::string &broker_url, const std::string &client_id)
    : broker_url_(broker_url), client_id_(client_id), connected_(false)
{
    std::string errstr;

    // Create configuration object
    RdKafka::Conf *conf = RdKafka::Conf::create(RdKafka::Conf::CONF_GLOBAL);

    // Set broker list
    if (conf->set("bootstrap.servers", broker_url_, errstr) != RdKafka::Conf::CONF_OK)
    {
        delete conf;
        throw std::runtime_error("Failed to set bootstrap.servers: " + errstr);
    }

    // Set client ID
    if (conf->set("client.id", client_id_, errstr) != RdKafka::Conf::CONF_OK)
    {
        delete conf;
        throw std::runtime_error("Failed to set client.id: " + errstr);
    }

    // Set delivery callback (optional, for error reporting)
    // We can use a simple callback or nullptr if not needed

    // Create producer
    producer_.reset(RdKafka::Producer::create(conf, errstr));
    if (!producer_)
    {
        delete conf;
        throw std::runtime_error("Failed to create Kafka producer: " + errstr);
    }

    delete conf;
    connected_ = true;
}

KafkaProducer::~KafkaProducer()
{
    if (producer_ && connected_)
    {
        try
        {
            // Flush any pending messages (wait up to 5 seconds)
            flush();
        }
        catch (const std::exception &e)
        {
            spdlog::error("Error closing Kafka producer: {}", e.what());
        }
    }
    // Producer will be automatically destroyed when unique_ptr goes out of scope
}

void KafkaProducer::publish(const std::string &topic, const std::string &message)
{
    if (!connected_ || !producer_)
    {
        throw std::runtime_error("Kafka producer is not connected");
    }

    std::lock_guard<std::mutex> lock(producer_mutex_);
    std::string errstr;

    // Create topic configuration
    RdKafka::Conf *tconf = RdKafka::Conf::create(RdKafka::Conf::CONF_TOPIC);

    // Create topic object (RdKafka will cache these internally)
    RdKafka::Topic *topic_obj = RdKafka::Topic::create(producer_.get(), topic, tconf, errstr);
    if (!topic_obj)
    {
        delete tconf;
        throw std::runtime_error("Failed to create topic: " + errstr);
    }

    delete tconf;

    // Produce message
    // Use the produce() variant with key as pointer+length
    // Signature: produce(Topic*, int32_t partition, int msgflags, void* payload, size_t len, const void* key, size_t key_len, void* msg_opaque)
    RdKafka::ErrorCode resp = producer_->produce(
        topic_obj,
        RdKafka::Topic::PARTITION_UA,        // Unassigned partition (let broker decide)
        RdKafka::Producer::RK_MSG_COPY,      // Copy payload (rdkafka will copy the data)
        const_cast<char *>(message.c_str()), // Payload (cast needed because produce takes void*, not const void*)
        message.size(),                      // Payload length
        nullptr,                             // No key
        0,                                   // Key length
        nullptr                              // No message opaque
    );

    if (resp != RdKafka::ERR_NO_ERROR)
    {
        std::string error_msg = RdKafka::err2str(resp);
        throw std::runtime_error("Failed to produce message: " + error_msg);
    }

    // Poll to handle delivery callbacks and trigger network events (non-blocking)
    producer_->poll(0);
}

void KafkaProducer::flush()
{
    if (!connected_ || !producer_)
    {
        return;
    }

    std::lock_guard<std::mutex> lock(producer_mutex_);

    // Flush all pending messages (wait up to 10 seconds)
    RdKafka::ErrorCode resp = producer_->flush(10000);
    if (resp != RdKafka::ERR_NO_ERROR)
    {
        spdlog::warn("Kafka flush returned: {}", RdKafka::err2str(resp));
    }
}

bool KafkaProducer::isConnected() const
{
    return connected_ && producer_ != nullptr;
}
