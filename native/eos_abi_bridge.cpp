#include <eos_sdk.h>
#include <eos_init.h>
#include <eos_connect.h>
#include <eos_logging.h>
#include <eos_p2p.h>

#if defined(_WIN32)
#include <windows.h>
#include <bcrypt.h>
#define MCD_EOS_EXPORT __declspec(dllexport)
#else
#include <random>
#define MCD_EOS_EXPORT __attribute__((visibility("default")))
#endif

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <string>

namespace
{
    enum class BridgeStatus : int
    {
        Initializing = 0,
        Ready = 1,
        Failed = 2,
    };

    struct EosBridge
    {
        EOS_HPlatform platform = nullptr;
        EOS_HConnect connect = nullptr;
        EOS_HP2P p2p = nullptr;
        EOS_ProductUserId localUser = nullptr;
        EOS_NotificationId requestNotification = EOS_INVALID_NOTIFICATIONID;
        EOS_NotificationId closedNotification = EOS_INVALID_NOTIFICATIONID;
        EOS_P2P_SocketId socket{};
        BridgeStatus status = BridgeStatus::Initializing;
        std::string error;
        std::string displayName;
        std::deque<std::string> closedPeers;
        bool initializedSdk = false;
        bool hosting = false;
    };

    void setError(EosBridge* bridge, const char* operation, EOS_EResult result)
    {
        bridge->status = BridgeStatus::Failed;
        bridge->error = operation;
        bridge->error += ": ";
        bridge->error += EOS_EResult_ToString(result);
    }

    void EOS_CALL onLogMessage(const EOS_LogMessage* message)
    {
        if (!message)
            return;
        std::fprintf(stderr, "EOS [%s] %s\n",
            message->Category ? message->Category : "Unknown",
            message->Message ? message->Message : "");
        std::fflush(stderr);
    }

    bool copyText(const std::string& value, char* output, unsigned int capacity)
    {
        if (!output || capacity == 0)
            return false;
        const size_t count = (std::min)(value.size(), static_cast<size_t>(capacity - 1));
        std::memcpy(output, value.data(), count);
        output[count] = '\0';
        return count == value.size();
    }

    std::string userIdString(EOS_ProductUserId user)
    {
        char buffer[EOS_PRODUCTUSERID_MAX_LENGTH + 1]{};
        int32_t length = sizeof(buffer);
        if (!user || EOS_ProductUserId_ToString(user, buffer, &length) != EOS_EResult::EOS_Success)
            return {};
        return buffer;
    }

    void beginDeviceLogin(EosBridge* bridge);

    void EOS_CALL onDeviceIdCreated(const EOS_Connect_CreateDeviceIdCallbackInfo* data)
    {
        auto* bridge = static_cast<EosBridge*>(data->ClientData);
        if (!bridge)
            return;
        if (data->ResultCode != EOS_EResult::EOS_Success
            && data->ResultCode != EOS_EResult::EOS_DuplicateNotAllowed)
        {
            setError(bridge, "EOS device identity creation failed", data->ResultCode);
            return;
        }
        beginDeviceLogin(bridge);
    }

    void EOS_CALL onLoginComplete(const EOS_Connect_LoginCallbackInfo* data)
    {
        auto* bridge = static_cast<EosBridge*>(data->ClientData);
        if (!bridge)
            return;
        if (data->ResultCode != EOS_EResult::EOS_Success || !EOS_ProductUserId_IsValid(data->LocalUserId))
        {
            setError(bridge, "EOS Connect login failed", data->ResultCode);
            return;
        }
        bridge->localUser = data->LocalUserId;
        bridge->status = BridgeStatus::Ready;
    }

    void beginDeviceLogin(EosBridge* bridge)
    {
        EOS_Connect_Credentials credentials{};
        credentials.ApiVersion = EOS_CONNECT_CREDENTIALS_API_LATEST;
        credentials.Token = nullptr;
        credentials.Type = EOS_EExternalCredentialType::EOS_ECT_DEVICEID_ACCESS_TOKEN;

        EOS_Connect_UserLoginInfo userInfo{};
        userInfo.ApiVersion = EOS_CONNECT_USERLOGININFO_API_LATEST;
        userInfo.DisplayName = bridge->displayName.c_str();

        EOS_Connect_LoginOptions options{};
        options.ApiVersion = EOS_CONNECT_LOGIN_API_LATEST;
        options.Credentials = &credentials;
        options.UserLoginInfo = &userInfo;
        EOS_Connect_Login(bridge->connect, &options, bridge, onLoginComplete);
    }

    void EOS_CALL onConnectionRequest(const EOS_P2P_OnIncomingConnectionRequestInfo* data)
    {
        auto* bridge = static_cast<EosBridge*>(data->ClientData);
        if (!bridge || !bridge->hosting || !data->SocketId)
            return;
        if (std::strncmp(data->SocketId->SocketName, bridge->socket.SocketName,
                EOS_P2P_SOCKETID_SOCKETNAME_SIZE) != 0)
            return;

        EOS_P2P_AcceptConnectionOptions options{};
        options.ApiVersion = EOS_P2P_ACCEPTCONNECTION_API_LATEST;
        options.LocalUserId = bridge->localUser;
        options.RemoteUserId = data->RemoteUserId;
        options.SocketId = &bridge->socket;
        EOS_P2P_AcceptConnection(bridge->p2p, &options);
    }

    void EOS_CALL onConnectionClosed(const EOS_P2P_OnRemoteConnectionClosedInfo* data)
    {
        auto* bridge = static_cast<EosBridge*>(data->ClientData);
        if (!bridge || !data->SocketId)
            return;
        if (std::strncmp(data->SocketId->SocketName, bridge->socket.SocketName,
                EOS_P2P_SOCKETID_SOCKETNAME_SIZE) != 0)
            return;
        const auto id = userIdString(data->RemoteUserId);
        if (!id.empty())
            bridge->closedPeers.push_back(id);
    }

    EOS_P2P_SocketId makeSocket(const char* socketName)
    {
        EOS_P2P_SocketId result{};
        result.ApiVersion = EOS_P2P_SOCKETID_API_LATEST;
        if (socketName)
        {
            std::strncpy(result.SocketName, socketName,
                sizeof(result.SocketName) - 1);
            result.SocketName[sizeof(result.SocketName) - 1] = '\0';
        }
        return result;
    }
}

extern "C"
{
    MCD_EOS_EXPORT void* mcd_eos_create(
        const char* productId, const char* sandboxId, const char* deploymentId,
        const char* clientId, const char* clientSecret, const char* cacheDirectory,
        const char* displayName, char* errorBuffer, unsigned int errorCapacity)
    {
        auto bridge = std::make_unique<EosBridge>();
        bridge->displayName = displayName && *displayName ? displayName : "Steve";

        EOS_InitializeOptions initialize{};
        initialize.ApiVersion = EOS_INITIALIZE_API_LATEST;
        initialize.ProductName = "Minecraft: D Edition";
        initialize.ProductVersion = "0.1";
        const EOS_EResult initializeResult = EOS_Initialize(&initialize);
        if (initializeResult != EOS_EResult::EOS_Success
            && initializeResult != EOS_EResult::EOS_AlreadyConfigured)
        {
            setError(bridge.get(), "EOS SDK initialization failed", initializeResult);
            copyText(bridge->error, errorBuffer, errorCapacity);
            return bridge.release();
        }
        bridge->initializedSdk = initializeResult == EOS_EResult::EOS_Success;
        EOS_Logging_SetCallback(onLogMessage);
        EOS_Logging_SetLogLevel(EOS_ELogCategory::EOS_LC_ALL_CATEGORIES,
            std::getenv("MDE_EOS_VERBOSE_LOGGING")
                ? EOS_ELogLevel::EOS_LOG_VeryVerbose
                : EOS_ELogLevel::EOS_LOG_Warning);

        EOS_Platform_Options platformOptions{};
        platformOptions.ApiVersion = EOS_PLATFORM_OPTIONS_API_LATEST;
        platformOptions.ProductId = productId;
        platformOptions.SandboxId = sandboxId;
        platformOptions.DeploymentId = deploymentId;
        platformOptions.ClientCredentials.ClientId = clientId;
        platformOptions.ClientCredentials.ClientSecret = clientSecret;
        platformOptions.bIsServer = EOS_FALSE;
        platformOptions.Flags = EOS_PF_DISABLE_OVERLAY | EOS_PF_DISABLE_SOCIAL_OVERLAY;
        platformOptions.CacheDirectory = cacheDirectory;
        platformOptions.TickBudgetInMilliseconds = 2;
        bridge->platform = EOS_Platform_Create(&platformOptions);
        if (!bridge->platform)
        {
            bridge->status = BridgeStatus::Failed;
            bridge->error = "EOS platform creation failed; verify data/eos.local.json";
            copyText(bridge->error, errorBuffer, errorCapacity);
            return bridge.release();
        }
        bridge->connect = EOS_Platform_GetConnectInterface(bridge->platform);
        bridge->p2p = EOS_Platform_GetP2PInterface(bridge->platform);
        if (!bridge->connect || !bridge->p2p)
        {
            bridge->status = BridgeStatus::Failed;
            bridge->error = "EOS Connect or P2P interface is unavailable";
            copyText(bridge->error, errorBuffer, errorCapacity);
            return bridge.release();
        }

        EOS_P2P_SetRelayControlOptions relay{};
        relay.ApiVersion = EOS_P2P_SETRELAYCONTROL_API_LATEST;
        relay.RelayControl = EOS_ERelayControl::EOS_RC_AllowRelays;
        const EOS_EResult relayResult = EOS_P2P_SetRelayControl(bridge->p2p, &relay);
        if (relayResult != EOS_EResult::EOS_Success)
        {
            setError(bridge.get(), "EOS relay setup failed", relayResult);
            copyText(bridge->error, errorBuffer, errorCapacity);
            return bridge.release();
        }

        EOS_Connect_CreateDeviceIdOptions device{};
        device.ApiVersion = EOS_CONNECT_CREATEDEVICEID_API_LATEST;
#if defined(_WIN32)
        device.DeviceModel = "Windows PC";
#else
        device.DeviceModel = "Mac";
#endif
        EOS_Connect_CreateDeviceId(bridge->connect, &device, bridge.get(), onDeviceIdCreated);
        return bridge.release();
    }

    MCD_EOS_EXPORT void mcd_eos_destroy(void* context)
    {
        std::unique_ptr<EosBridge> bridge(static_cast<EosBridge*>(context));
        if (!bridge)
            return;
        if (bridge->p2p && bridge->requestNotification != EOS_INVALID_NOTIFICATIONID)
            EOS_P2P_RemoveNotifyPeerConnectionRequest(bridge->p2p, bridge->requestNotification);
        if (bridge->p2p && bridge->closedNotification != EOS_INVALID_NOTIFICATIONID)
            EOS_P2P_RemoveNotifyPeerConnectionClosed(bridge->p2p, bridge->closedNotification);
        if (bridge->platform)
            EOS_Platform_Release(bridge->platform);
        if (bridge->initializedSdk)
            EOS_Shutdown();
    }

    MCD_EOS_EXPORT void mcd_eos_tick(void* context)
    {
        auto* bridge = static_cast<EosBridge*>(context);
        if (bridge && bridge->platform)
            EOS_Platform_Tick(bridge->platform);
    }

    MCD_EOS_EXPORT int mcd_eos_status(void* context)
    {
        auto* bridge = static_cast<EosBridge*>(context);
        return bridge ? static_cast<int>(bridge->status) : static_cast<int>(BridgeStatus::Failed);
    }

    MCD_EOS_EXPORT int mcd_eos_copy_error(void* context, char* output, unsigned int capacity)
    {
        auto* bridge = static_cast<EosBridge*>(context);
        return bridge && copyText(bridge->error, output, capacity) ? 1 : 0;
    }

    MCD_EOS_EXPORT int mcd_eos_copy_local_user_id(void* context, char* output, unsigned int capacity)
    {
        auto* bridge = static_cast<EosBridge*>(context);
        if (!bridge || bridge->status != BridgeStatus::Ready)
            return 0;
        return copyText(userIdString(bridge->localUser), output, capacity) ? 1 : 0;
    }

    MCD_EOS_EXPORT int mcd_eos_configure_socket(void* context,
        const char* socketName, int hosting, int forceRelays)
    {
        auto* bridge = static_cast<EosBridge*>(context);
        if (!bridge || bridge->status != BridgeStatus::Ready || !socketName)
            return 0;
        const size_t length = std::strlen(socketName);
        if (length < 1 || length > 32)
            return 0;

        if (bridge->requestNotification != EOS_INVALID_NOTIFICATIONID)
            EOS_P2P_RemoveNotifyPeerConnectionRequest(bridge->p2p, bridge->requestNotification);
        if (bridge->closedNotification != EOS_INVALID_NOTIFICATIONID)
            EOS_P2P_RemoveNotifyPeerConnectionClosed(bridge->p2p, bridge->closedNotification);

        bridge->socket = makeSocket(socketName);
        bridge->hosting = hosting != 0;

        EOS_P2P_SetRelayControlOptions relay{};
        relay.ApiVersion = EOS_P2P_SETRELAYCONTROL_API_LATEST;
        relay.RelayControl = forceRelays ? EOS_ERelayControl::EOS_RC_ForceRelays
            : EOS_ERelayControl::EOS_RC_AllowRelays;
        if (EOS_P2P_SetRelayControl(bridge->p2p, &relay) != EOS_EResult::EOS_Success)
            return 0;

        EOS_P2P_AddNotifyPeerConnectionRequestOptions request{};
        request.ApiVersion = EOS_P2P_ADDNOTIFYPEERCONNECTIONREQUEST_API_LATEST;
        request.LocalUserId = bridge->localUser;
        request.SocketId = &bridge->socket;
        bridge->requestNotification = EOS_P2P_AddNotifyPeerConnectionRequest(
            bridge->p2p, &request, bridge, onConnectionRequest);

        EOS_P2P_AddNotifyPeerConnectionClosedOptions closed{};
        closed.ApiVersion = EOS_P2P_ADDNOTIFYPEERCONNECTIONCLOSED_API_LATEST;
        closed.LocalUserId = bridge->localUser;
        closed.SocketId = &bridge->socket;
        bridge->closedNotification = EOS_P2P_AddNotifyPeerConnectionClosed(
            bridge->p2p, &closed, bridge, onConnectionClosed);
        return bridge->requestNotification != EOS_INVALID_NOTIFICATIONID
            && bridge->closedNotification != EOS_INVALID_NOTIFICATIONID;
    }

    MCD_EOS_EXPORT int mcd_eos_send(void* context, const char* remoteUserId,
        const char* socketName, unsigned char channel, const void* data, unsigned int length)
    {
        auto* bridge = static_cast<EosBridge*>(context);
        if (!bridge || bridge->status != BridgeStatus::Ready || !data
            || length == 0 || length > EOS_P2P_MAX_PACKET_SIZE)
            return 0;
        EOS_ProductUserId remote = EOS_ProductUserId_FromString(remoteUserId);
        if (!EOS_ProductUserId_IsValid(remote))
            return 0;
        const auto socket = makeSocket(socketName);
        EOS_P2P_SendPacketOptions options{};
        options.ApiVersion = EOS_P2P_SENDPACKET_API_LATEST;
        options.LocalUserId = bridge->localUser;
        options.RemoteUserId = remote;
        options.SocketId = &socket;
        options.Channel = channel;
        options.DataLengthBytes = length;
        options.Data = data;
        options.bAllowDelayedDelivery = EOS_TRUE;
        options.Reliability = EOS_EPacketReliability::EOS_PR_ReliableOrdered;
        options.bDisableAutoAcceptConnection = EOS_FALSE;
        return EOS_P2P_SendPacket(bridge->p2p, &options) == EOS_EResult::EOS_Success ? 1 : 0;
    }

    MCD_EOS_EXPORT int mcd_eos_receive(void* context,
        char* remoteOutput, unsigned int remoteCapacity,
        char* socketOutput, unsigned int socketCapacity,
        unsigned char* channelOutput, void* dataOutput,
        unsigned int dataCapacity, unsigned int* lengthOutput)
    {
        auto* bridge = static_cast<EosBridge*>(context);
        if (!bridge || bridge->status != BridgeStatus::Ready || !dataOutput || !lengthOutput)
            return -1;
        EOS_P2P_GetNextReceivedPacketSizeOptions sizeOptions{};
        sizeOptions.ApiVersion = EOS_P2P_GETNEXTRECEIVEDPACKETSIZE_API_LATEST;
        sizeOptions.LocalUserId = bridge->localUser;
        uint32_t packetSize = 0;
        const EOS_EResult sizeResult = EOS_P2P_GetNextReceivedPacketSize(
            bridge->p2p, &sizeOptions, &packetSize);
        if (sizeResult == EOS_EResult::EOS_NotFound)
            return 0;
        if (sizeResult != EOS_EResult::EOS_Success || packetSize > dataCapacity)
            return -1;

        EOS_P2P_ReceivePacketOptions receive{};
        receive.ApiVersion = EOS_P2P_RECEIVEPACKET_API_LATEST;
        receive.LocalUserId = bridge->localUser;
        receive.MaxDataSizeBytes = dataCapacity;
        EOS_ProductUserId remote = nullptr;
        EOS_P2P_SocketId socket{};
        uint8_t channel = 0;
        uint32_t written = 0;
        const EOS_EResult result = EOS_P2P_ReceivePacket(bridge->p2p, &receive,
            &remote, &socket, &channel, dataOutput, &written);
        if (result != EOS_EResult::EOS_Success)
            return -1;
        if (!copyText(userIdString(remote), remoteOutput, remoteCapacity)
            || !copyText(socket.SocketName, socketOutput, socketCapacity))
            return -1;
        if (channelOutput)
            *channelOutput = channel;
        *lengthOutput = written;
        return 1;
    }

    MCD_EOS_EXPORT int mcd_eos_poll_closed(void* context,
        char* remoteOutput, unsigned int remoteCapacity)
    {
        auto* bridge = static_cast<EosBridge*>(context);
        if (!bridge || bridge->closedPeers.empty())
            return 0;
        const auto remote = bridge->closedPeers.front();
        bridge->closedPeers.pop_front();
        return copyText(remote, remoteOutput, remoteCapacity) ? 1 : -1;
    }

    MCD_EOS_EXPORT void mcd_eos_close_peer(void* context,
        const char* remoteUserId, const char* socketName)
    {
        auto* bridge = static_cast<EosBridge*>(context);
        if (!bridge || !bridge->localUser)
            return;
        EOS_ProductUserId remote = EOS_ProductUserId_FromString(remoteUserId);
        if (!EOS_ProductUserId_IsValid(remote))
            return;
        const auto socket = makeSocket(socketName);
        EOS_P2P_CloseConnectionOptions options{};
        options.ApiVersion = EOS_P2P_CLOSECONNECTION_API_LATEST;
        options.LocalUserId = bridge->localUser;
        options.RemoteUserId = remote;
        options.SocketId = &socket;
        EOS_P2P_CloseConnection(bridge->p2p, &options);
    }

    MCD_EOS_EXPORT int mcd_eos_random_socket_name(char* output, unsigned int capacity)
    {
        static constexpr char alphabet[] =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        if (!output || capacity < 25)
            return 0;
        unsigned char randomBytes[24]{};
#if defined(_WIN32)
        if (BCryptGenRandom(nullptr, randomBytes, sizeof(randomBytes),
                BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
            return 0;
#else
        std::random_device random;
        for (auto& value : randomBytes)
            value = static_cast<unsigned char>(random());
#endif
        for (size_t i = 0; i < sizeof(randomBytes); ++i)
            output[i] = alphabet[randomBytes[i] & 63];
        output[sizeof(randomBytes)] = '\0';
        return 1;
    }
}
