#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "FFMpegDownloader.h"
#import "Headers/YTUIResources.h"
#import "Headers/YTMActionSheetController.h"
#import "Headers/YTMActionRowView.h"
#import "Headers/YTIPlayerOverlayRenderer.h"
#import "Headers/YTIPlayerOverlayActionSupportedRenderers.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerView.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"
#import "Headers/YTIFormatStream.h"
#import "Headers/YTAlertView.h"
#import "Headers/ELMNodeController.h"

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

#pragma mark - Bounded player response resolution

// Newer YouTube Music builds no longer expose -[YTPlayerViewController playerResponse]
// (and may rename related accessors). Direct property/selector access then crashes with
// "unrecognized selector". To stay robust without scanning large object graphs at launch,
// we resolve the player response lazily and only when the download badge is tapped, using
// a strictly bounded breadth-first walk over a small set of known relationship keys.
//
// The walk is bounded three ways: a visited set prevents cycles, a depth cap limits how far
// we follow relationships, and a node cap limits total objects inspected per tap. It is never
// run in %ctor / app startup, and it never scans windows, the root view controller, or the
// full view hierarchy.

static const NSUInteger kYTMUResolveMaxDepth = 4;
static const NSUInteger kYTMUResolveMaxNodes = 60;

// KVC read that returns nil instead of throwing when the key is unknown on the target object.
static id YTMUSafeValueForKey(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Dictionary-aware accessor used when reading nested player/streaming data.
static id YTMUObjectForKey(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    if ([object isKindOfClass:[NSDictionary class]]) return ((NSDictionary *)object)[key];
    return YTMUSafeValueForKey(object, key);
}

static NSString *YTMUStringForKey(id object, NSString *key) {
    id value = YTMUObjectForKey(object, key);
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return @"";
}

static NSString *YTMUSanitizeFileComponent(NSString *string) {
    NSString *safe = string.length ? string : @"Unknown";
    NSArray<NSString *> *bad = @[@"/", @"\\", @":", @"\n", @"\r", @"\t"];
    for (NSString *part in bad) {
        safe = [safe stringByReplacingOccurrencesOfString:part withString:@""];
    }
    safe = [safe stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return safe.length ? safe : @"Unknown";
}

// Relationship keys we are willing to traverse. Deliberately small and player-centric so the
// walk stays local to the now-playing/player object cluster.
static NSArray<NSString *> *YTMUTraversalKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"parentViewController",
            @"playerViewController", @"_playerViewController",
            @"watchViewController", @"_watchViewController",
            @"playerViewDelegate", @"_playerViewDelegate",
            @"playerController", @"_playerController",
            @"player", @"_player",
            @"delegate", @"_delegate",
            @"presentedViewController"
        ];
    });
    return keys;
}

// Generic bounded BFS. Returns the first non-nil result produced by `match`.
static id YTMUBoundedSearch(NSArray *seeds, id (^match)(id node)) {
    if (seeds.count == 0 || !match) return nil;

    NSMutableArray *queue = [NSMutableArray array];
    NSMutableArray<NSNumber *> *depths = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];

    for (id seed in seeds) {
        if (seed) {
            [queue addObject:seed];
            [depths addObject:@0];
        }
    }

    NSUInteger processed = 0;
    NSArray<NSString *> *keys = YTMUTraversalKeys();

    while (queue.count > 0 && processed < kYTMUResolveMaxNodes) {
        id node = queue.firstObject;
        NSUInteger depth = depths.firstObject.unsignedIntegerValue;
        [queue removeObjectAtIndex:0];
        [depths removeObjectAtIndex:0];

        if (!node) continue;
        NSValue *identity = [NSValue valueWithNonretainedObject:node];
        if ([visited containsObject:identity]) continue;
        [visited addObject:identity];
        processed++;

        id result = match(node);
        if (result) return result;

        if (depth >= kYTMUResolveMaxDepth) continue;

        for (NSString *key in keys) {
            id value = YTMUSafeValueForKey(node, key);
            if (value && value != node) {
                [queue addObject:value];
                [depths addObject:@(depth + 1)];
            }
        }

        if ([node isKindOfClass:[UIViewController class]]) {
            for (UIViewController *child in [(UIViewController *)node childViewControllers]) {
                if (child) {
                    [queue addObject:child];
                    [depths addObject:@(depth + 1)];
                }
            }
        }
    }

    return nil;
}

// Locate a YTPlayerViewController instance near the seed objects.
static YTPlayerViewController *YTMUResolvePlayerViewController(NSArray *seeds) {
    Class playerClass = NSClassFromString(@"YTPlayerViewController");
    if (!playerClass) return nil;
    return (YTPlayerViewController *)YTMUBoundedSearch(seeds, ^id(id node) {
        return [node isKindOfClass:playerClass] ? node : nil;
    });
}

// Locate the player response value near the seed objects, reading it via safe KVC so a missing
// accessor on newer builds returns nil instead of crashing.
static id YTMUResolvePlayerResponse(NSArray *seeds) {
    return YTMUBoundedSearch(seeds, ^id(id node) {
        return YTMUSafeValueForKey(node, @"playerResponse") ?: YTMUSafeValueForKey(node, @"_playerResponse");
    });
}

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)downloadAudio:(YTPlayerViewController *)playerResponse;
- (void)downloadCoverImage:(YTPlayerViewController *)playerResponse;
- (NSString *)getURLFromManifest:(NSURL *)manifest;
- (NSData *)dataFromURL:(NSURL *)url;
@end

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {

    if (class_getInstanceVariable([self class], "_controller") == NULL) {
        return %orig;
    }


    if (class_getInstanceVariable([self class], "_tapRecognizer") == NULL) {
        return %orig;
    }

    ELMNodeController *node = [self valueForKey:@"_controller"];
    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];

    if (![node.key isEqualToString:@"music_download_badge_1"]) {
        return %orig;
    }

    if (![tapRecognizer.view._viewControllerForAncestor isKindOfClass:%c(YTMNowPlayingViewController)]) {
        return %orig;
    }

    YTMNowPlayingViewController *playingVC = (YTMNowPlayingViewController *)tapRecognizer.view._viewControllerForAncestor;

    // Fast path: the historical relationship chain. On older builds this resolves immediately.
    YTMWatchViewController *watchVC = (YTMWatchViewController *)playingVC.parentViewController;
    YTPlayerViewController *playerVC = watchVC.playerViewController;

    // Fallback: bounded search seeded from the now-playing controller, used only when the
    // direct chain is broken on newer builds. Never scans windows or the full view tree.
    if (![playerVC isKindOfClass:%c(YTPlayerViewController)]) {
        playerVC = YTMUResolvePlayerViewController(@[playingVC]);
    }

    id playerResponse = YTMUResolvePlayerResponse(playerVC ? @[playerVC, playingVC] : @[playingVC]);

    if (playerVC && playerResponse) {
        YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
        sheetController.sourceView = tapRecognizer.view;
        [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^ {
            [self downloadAudio:playerVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
            [self downloadCoverImage:playerVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
            return %orig;
        }]];

        if (YTMU(@"downloadAudio") && YTMU(@"downloadCoverImage")) {
            [sheetController presentFromViewController:playingVC animated:YES completion:nil];
        } else if (YTMU(@"downloadAudio")) {
            [self downloadAudio:playerVC];
        } else if (YTMU(@"downloadCoverImage")) {
            [self downloadCoverImage:playerVC];
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
    }
}

%new
- (void)downloadAudio:(YTPlayerViewController *)playerVC {
    id playerResponse = YTMUResolvePlayerResponse(playerVC ? @[playerVC] : @[]);

    if (!playerResponse) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
        return;
    }

    id playerData = YTMUObjectForKey(playerResponse, @"playerData");
    id videoDetails = YTMUObjectForKey(playerData, @"videoDetails");
    id streamingData = YTMUObjectForKey(playerData, @"streamingData");

    NSString *title = YTMUSanitizeFileComponent(YTMUStringForKey(videoDetails, @"title"));
    NSString *author = YTMUSanitizeFileComponent(YTMUStringForKey(videoDetails, @"author"));
    NSString *urlStr = YTMUStringForKey(streamingData, @"hlsManifestURL");

    if (urlStr.length == 0) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
        return;
    }

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    ffmpeg.tempName = YTMUStringForKey(playerVC, @"contentVideoID");
    ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
    id durationValue = YTMUObjectForKey(playerVC, @"currentVideoTotalMediaTime");
    ffmpeg.duration = [durationValue respondsToSelector:@selector(doubleValue)] ? round([durationValue doubleValue]) : 0;

    id thumbnailDetails = YTMUObjectForKey(videoDetails, @"thumbnail");
    NSMutableArray *thumbnailsArray = YTMUObjectForKey(thumbnailDetails, @"thumbnailsArray");
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
    NSString *thumbnailURLStr = thumbnail.URL;

    // Manifest resolution does blocking network I/O, so run it off the main thread behind an
    // indeterminate HUD. This prevents the UI freeze / "never completes" state when the network
    // stalls; the HUD is always torn down on completion or failure.
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    hud.mode = MBProgressHUDModeIndeterminate;
    hud.label.text = LOC(@"DOWNLOADING");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *extractedURL = [self getURLFromManifest:[NSURL URLWithString:urlStr]];

        NSData *imageData = nil;
        if (extractedURL.length > 0 && thumbnailURLStr.length > 0) {
            imageData = [self dataFromURL:[NSURL URLWithString:thumbnailURLStr]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [hud hideAnimated:YES];

            if (extractedURL.length > 0) {
                [ffmpeg downloadAudio:extractedURL];

                if (imageData) {
                    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
                    NSURL *folderURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
                    [[NSFileManager defaultManager] createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:nil];
                    NSURL *coverURL = [folderURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ - %@.png", author, title]];
                    [imageData writeToURL:coverURL atomically:YES];
                }
            } else {
                YTAlertView *alertView = [%c(YTAlertView) infoDialog];
                alertView.title = LOC(@"OOPS");
                alertView.subtitle = LOC(@"LINK_NOT_FOUND");
                [alertView show];
            }
        });
    });
}

%new
- (NSData *)dataFromURL:(NSURL *)url {
    if (!url) return nil;

    // Bounded fetch with a hard timeout so a stalled network never hangs the download flow
    // forever (previously -dataWithContentsOfURL: could block indefinitely). Callers run this
    // off the main thread.
    __block NSData *result = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 20.0;
    config.timeoutIntervalForResource = 30.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error) result = data;
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];

    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35.0 * NSEC_PER_SEC)));
    [session finishTasksAndInvalidate];

    return result;
}

%new
- (NSString *)getURLFromManifest:(NSURL *)manifest {
    if (!manifest) return nil;

    NSData *manifestData = [self dataFromURL:manifest];
    if (manifestData.length == 0) return nil;

    NSString *manifestString = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    if (manifestString.length == 0) return nil;

    NSArray *manifestLines = [manifestString componentsSeparatedByString:@"\n"];

    NSArray *groupIDS = @[@"234", @"233"]; // Our priority to find group id 234
    for (NSString *groupID in groupIDS) {
        for (NSString *line in manifestLines) {
            NSString *searchString = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
            if ([line containsString:searchString]) {
                NSRange startRange = [line rangeOfString:@"https://"];
                NSRange endRange = [line rangeOfString:@"index.m3u8"];

                if (startRange.location != NSNotFound && endRange.location != NSNotFound && NSMaxRange(endRange) > startRange.location) {
                    NSRange targetRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
                    return [line substringWithRange:targetRange];
                }
            }
        }
    }

    return nil;
}

%new
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC {
    id playerResponse = YTMUResolvePlayerResponse(playerVC ? @[playerVC] : @[]);
    if (!playerResponse) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
        return;
    }

    id playerData = YTMUObjectForKey(playerResponse, @"playerData");
    id videoDetails = YTMUObjectForKey(playerData, @"videoDetails");
    id thumbnailDetails = YTMUObjectForKey(videoDetails, @"thumbnail");
    NSMutableArray *thumbnailsArray = YTMUObjectForKey(thumbnailDetails, @"thumbnailsArray");
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];

    if (thumbnail.URL.length == 0) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
        return;
    }

    NSString *thumbnailURL = [thumbnail.URL stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"w%u-h%u-", thumbnail.width, thumbnail.width] withString:@"w2048-h2048-"];

    // FFMpegDownloader manages its own HUD (with success/failure states) and performs the
    // network fetch off the main thread, so it cannot hang the UI.
    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    [ffmpeg downloadImage:[NSURL URLWithString:thumbnailURL]];
}
%end
