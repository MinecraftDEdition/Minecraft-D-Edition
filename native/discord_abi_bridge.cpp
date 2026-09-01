#define DISCORDPP_IMPLEMENTATION
#include <discordpp.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#if defined(_WIN32)
#define MCD_DISCORD_EXPORT __declspec(dllexport)
#else
#define MCD_DISCORD_EXPORT __attribute__((visibility("default")))
#endif

namespace
{
    std::unique_ptr<discordpp::Client> client;

    std::optional<std::string> optionalText(const char* value)
    {
        if (!value || !*value)
            return std::nullopt;
        return std::string(value);
    }
}

extern "C" MCD_DISCORD_EXPORT int mcdDiscordInitialize(std::uint64_t applicationId)
{
    try
    {
        if (client)
            return 1;
        client = std::make_unique<discordpp::Client>();
        client->SetApplicationId(applicationId);
        return 1;
    }
    catch (...)
    {
        client.reset();
        return 0;
    }
}

extern "C" MCD_DISCORD_EXPORT void mcdDiscordUpdate(
    const char* details,
    const char* state,
    const char* largeImage,
    const char* largeText)
{
    try
    {
        if (!client)
            return;

        discordpp::Activity activity;
        activity.SetType(discordpp::ActivityTypes::Playing);
        activity.SetDetails(optionalText(details));
        activity.SetState(optionalText(state));

        discordpp::ActivityAssets assets;
        assets.SetLargeImage(optionalText(largeImage));
        assets.SetLargeText(optionalText(largeText));
        activity.SetAssets(std::move(assets));

        client->UpdateRichPresence(std::move(activity),
            [](discordpp::ClientResult) {});
    }
    catch (...)
    {
        // Presence is optional. SDK failures must never affect the game.
    }
}

extern "C" MCD_DISCORD_EXPORT void mcdDiscordRunCallbacks()
{
    try
    {
        if (client)
            discordpp::RunCallbacks();
    }
    catch (...)
    {
    }
}

extern "C" MCD_DISCORD_EXPORT void mcdDiscordShutdown()
{
    try
    {
        if (!client)
            return;
        client->ClearRichPresence();
        discordpp::RunCallbacks();
        client.reset();
    }
    catch (...)
    {
        client.reset();
    }
}
