#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>

namespace
{
SPUStandardUpdaterController* updaterController = nil;
}

extern "C" void mcdUpdaterStart()
{
    @autoreleasepool
    {
        if (updaterController != nil)
            return;

        updaterController = [[SPUStandardUpdaterController alloc]
            initWithStartingUpdater:YES
            updaterDelegate:nil
            userDriverDelegate:nil];
        SPUUpdater* updater = updaterController.updater;
        if (updater.automaticallyChecksForUpdates)
            [updater checkForUpdatesInBackground];
    }
}
