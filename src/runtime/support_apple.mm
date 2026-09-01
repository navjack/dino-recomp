// Apple-specific helpers declared in support.hpp.
//
// The header says these are "Implemented in support_apple.mm", but no such file exists
// upstream, so the macOS link fails on dispatch_on_ui_thread and
// get_bundle_resource_directory. This supplies them.

#include "support.hpp"

#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>

namespace dino::runtime {

    void dispatch_on_ui_thread(std::function<void()> func) {
        // AppKit requires file dialogs and alerts to run on the main thread, but callers
        // reach here from the game/UI threads. Run inline when already on main so a caller
        // that is on the main thread is not deferred to a later runloop turn.
        if ([NSThread isMainThread]) {
            func();
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            func();
        });
    }

    std::optional<std::filesystem::path> get_application_support_directory() {
        @autoreleasepool {
            NSArray<NSURL *> *urls = [[NSFileManager defaultManager]
                URLsForDirectory:NSApplicationSupportDirectory
                       inDomains:NSUserDomainMask];
            NSString *path = urls.firstObject.path;
            if (path == nil) {
                return std::nullopt;
            }
            return std::filesystem::path(path.UTF8String);
        }
    }

    std::filesystem::path get_bundle_resource_directory() {
        @autoreleasepool {
            // For a bare (unbundled) executable this is the directory containing it, which
            // is the right answer for get_asset_path() in a plain build tree too.
            NSString *path = [[NSBundle mainBundle] resourcePath];
            if (path == nil) {
                return std::filesystem::current_path();
            }
            return std::filesystem::path(path.UTF8String);
        }
    }

    std::filesystem::path get_bundle_directory() {
        @autoreleasepool {
            NSString *path = [[NSBundle mainBundle] bundlePath];
            if (path == nil) {
                return std::filesystem::current_path();
            }
            return std::filesystem::path(path.UTF8String);
        }
    }

}
